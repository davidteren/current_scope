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

  test "org permission checks load the bundle once across many records" do
    assign(@alice, role("Reader", "reports#show"))
    reports = Array.new(20) { |i| Report.create!(title: "Report #{i}", requested_by: @bob) }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].include?("current_scope_role_permissions")
    end
    reports.each { |report| assert @resolver.allow?(subject: @alice, permission: "reports#show", record: report) }
    assert_equal 1, queries.size, "one preload must replace per-record permission queries"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "building a permission on a cached role grants nothing until save" do
    assign(@alice, role("Reader", "reports#index"))
    held = @resolver.org_role(@alice)
    permission = held.role_permissions.build(permission_key: "reports#show")

    assert_not @resolver.allow?(subject: @alice, permission: "reports#show")
    assert_equal [ "reports#index" ], held.permission_keys
    assert permission.new_record?
    permission.save!
    assert @resolver.allow?(subject: @alice, permission: "reports#show")
  end

  test "unsaved join edits neither grant nor revoke persisted permissions" do
    assign(@alice, role("Reader", "reports#index"))
    held = @resolver.org_role(@alice)
    permission = held.role_permissions.first
    permission.permission_key = "reports#show"

    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show")
    assert_equal [ "reports#index" ], held.permission_keys
    assert_equal "reports#show", permission.permission_key
    held.permission_keys = [ "reports#approve" ]
    assert_equal [ "reports#approve" ], held.permission_keys, "the explicit role-editor draft remains available"
    assert_not held.grants?("reports#approve")
  end

  test "role full access changes invalidate the request cache" do
    held = role("Owner", full_access: true)
    assign(@alice, held)
    assert @resolver.full_access?(@alice)
    held.update!(full_access: false)
    assert_not @resolver.full_access?(@alice)
  end

  test "rolled back full access and role deletion cannot leave a cached decision" do
    held = role("Reader", "reports#index")
    assign(@alice, held)
    CurrentScope::Role.transaction(requires_new: true) do
      held.update!(full_access: true)
      assert @resolver.full_access?(@alice)
      raise ActiveRecord::Rollback
    end
    assert_not @resolver.full_access?(@alice)
    CurrentScope::Role.transaction(requires_new: true) do
      CurrentScope::Role.find(held.id).destroy!
      assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
      raise ActiveRecord::Rollback
    end
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "direct permission key changes invalidate cached permissions" do
    held = role("Reader", "reports#index")
    assign(@alice, held)
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    held.role_permissions.first.update!(permission_key: "reports#show")
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
    assert @resolver.allow?(subject: @alice, permission: "reports#show")
  end

  test "permission edits and rollback invalidate the request cache" do
    held = role("Reader", "reports#index")
    assign(@alice, held)
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    held.update!(permission_keys: [])
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
    CurrentScope::Role.transaction(requires_new: true) do
      held.update!(permission_keys: [ "reports#index" ])
      assert @resolver.allow?(subject: @alice, permission: "reports#index")
      raise ActiveRecord::Rollback
    end
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "direct permission writes and rollback refresh loaded grants" do
    held = role("Reader")
    assign(@alice, held)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
    permission = held.role_permissions.create!(permission_key: "reports#index")
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    CurrentScope::RolePermission.transaction(requires_new: true) do
      permission.destroy!
      assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
      raise ActiveRecord::Rollback
    end
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    CurrentScope::RolePermission.find(permission.id).destroy!
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "a rolled back org assignment does not remain cached" do
    held = role("Reader", "reports#index")
    CurrentScope::RoleAssignment.transaction(requires_new: true) do
      assign(@alice, held)
      assert @resolver.allow?(subject: @alice, permission: "reports#index")
      raise ActiveRecord::Rollback
    end
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "replacing a preloaded role bundle updates the same role object" do
    held = role("Reader", "reports#index")
    held.role_permissions.load
    held.update!(permission_keys: [ "reports#show" ])
    assert_not held.grants?("reports#index")
    assert held.grants?("reports#show")
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
