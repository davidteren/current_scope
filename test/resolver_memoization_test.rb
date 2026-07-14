require "test_helper"

# Per-request memoization of the resolver's org-role lookup (CurrentScope::Current).
# The decision is unchanged; only the repeated RoleAssignment lookup is cached,
# and it's invalidated on any org-role write so a same-request grant is never stale.
class ResolverMemoizationTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
  end

  def assign(user, role)
    CurrentScope::RoleAssignment.create!(subject: user, role: role)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  # Count only queries against the org-role table, so unrelated grants? / scoped
  # lookups don't muddy the assertion.
  def role_assignment_queries
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if payload[:name] == "SCHEMA"
      count += 1 if payload[:sql] =~ /current_scope_role_assignments/i
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  test "the org-role lookup runs once across repeated gate checks in a request" do
    assign(@alice, role("Member", "reports#index", "reports#show"))
    queries = role_assignment_queries do
      3.times { @resolver.allow?(subject: @alice, permission: "reports#index") }
    end
    assert_equal 1, queries, "expected the org-role lookup to be memoized after the first check"
  end

  test "a 'no role' result is cached too (repeated deny is one lookup, not N)" do
    queries = role_assignment_queries do
      3.times { assert_not @resolver.allow?(subject: @alice, permission: "reports#index") }
    end
    assert_equal 1, queries
  end

  test "a grant within the same request is seen by a later check (memo invalidated on write)" do
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index") # caches: no role
    assign(@alice, role("Member", "reports#index"))                           # after_save busts the memo
    assert @resolver.allow?(subject: @alice, permission: "reports#index"), "stale memo hid a fresh grant"
  end

  test "clearing a role within the same request is seen by a later check" do
    assign(@alice, role("Member", "reports#index"))
    assert @resolver.allow?(subject: @alice, permission: "reports#index") # caches the role
    CurrentScope::RoleAssignment.find_by(subject: @alice).destroy!         # after_destroy busts the memo
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "the memo is keyed by subject" do
    assign(@alice, role("A", "reports#index"))
    assign(@bob, role("B", "reports#show"))
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show")
    assert @resolver.allow?(subject: @bob, permission: "reports#show")
    assert_not @resolver.allow?(subject: @bob, permission: "reports#index")
  end
end
