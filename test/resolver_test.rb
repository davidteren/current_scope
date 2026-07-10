require "test_helper"

class ResolverTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
  end

  def assign(user, role)
    CurrentScope::RoleAssignment.create!(subject: user, role: role)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  test "denies a nil subject (fail closed)" do
    assert_not @resolver.allow?(subject: nil, permission: "reports#index")
  end

  test "denies a subject with no role and no scoped grants (default deny)" do
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "denies when the org-wide role lacks the permission" do
    assign(@alice, role("Member", "reports#index"))
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy")
  end

  test "allows when the org-wide role grants the permission" do
    assign(@alice, role("Member", "reports#index"))
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "full_access grants everything, including future permissions" do
    assign(@alice, role("Owner", full_access: true))
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    assert @resolver.allow?(subject: @alice, permission: "things#added_next_sprint")
  end

  test "SoD veto: the initiator cannot approve their own record" do
    assign(@bob, role("Reviewer", "reports#approve"))
    assert_not @resolver.allow?(subject: @bob, permission: "reports#approve", record: @report)
  end

  test "SoD veto overrides full_access" do
    assign(@bob, role("Owner", full_access: true))
    assert_not @resolver.allow?(subject: @bob, permission: "reports#approve", record: @report)
    assert @resolver.allow?(subject: @bob, permission: "reports#destroy", record: @report)
  end

  test "SoD does not block a different subject" do
    assign(@alice, role("Reviewer", "reports#approve"))
    assert @resolver.allow?(subject: @alice, permission: "reports#approve", record: @report)
  end

  test "SoD only applies to configured actions" do
    assign(@bob, role("Editor", "reports#update"))
    assert @resolver.allow?(subject: @bob, permission: "reports#update", record: @report)
  end

  test "scoped role grants the permission on that record only" do
    editor = role("Editor", "reports#show")
    other = Report.create!(title: "Q4", requested_by: @bob)
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#show", record: @report)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: other)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
  end

  test "scoped full_access role grants any action on that record" do
    owner = role("RecordOwner", full_access: true)
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: owner, resource: @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
  end

  test "scoped role never leaks to org-wide checks" do
    editor = role("Editor", "reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
  end
end
