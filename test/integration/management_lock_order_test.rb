require "test_helper"

# SQLite omits FOR UPDATE from SQL. Observe the locking relation before the
# adapter executes it, while still driving the real controller transaction.
module ManagementLockObservation
  def exec_queries(...)
    if (observed = Thread.current[:management_lock_observation]) && lock_value
      observed << [ klass.name, where_clause.empty?, order_values.any?, connection.transaction_open? ]
    end
    super
  end
end
ActiveRecord::Relation.prepend(ManagementLockObservation)

class ManagementLockOrderTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    @member = User.create!(name: "Member")
    @owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @role = CurrentScope::Role.create!(name: "Editable")
    CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    @project = Project.create!(name: "Project")
  end

  teardown { Thread.current[:management_lock_observation] = nil }

  def observe_locks
    Thread.current[:management_lock_observation] = []
    yield
    locks = Thread.current[:management_lock_observation]
    assert_equal [ "CurrentScope::Role", true, true, true ], locks.first,
      "every console mutation must first lock all roles in order inside its transaction"
  ensure
    Thread.current[:management_lock_observation] = nil
  end

  def headers = { "X-User-Id" => @owner.id.to_s }

  test "org and scoped assignment paths take the same first lock" do
    observe_locks do
      post current_scope.role_assignments_url, params: { subject_gid: @member.to_gid.to_s, role_id: @role.id }, headers: headers
      assert_response :redirect
    end
    org = CurrentScope::RoleAssignment.find_by!(subject: @member)
    observe_locks do
      delete current_scope.role_assignment_url(org), headers: headers
      assert_response :redirect
    end
    observe_locks do
      post current_scope.scoped_role_assignments_url, params: { subject_gid: @member.to_gid.to_s, role_id: @role.id, resource_gid: @project.to_gid.to_s }, headers: headers
      assert_response :redirect
    end
    scoped = CurrentScope::ScopedRoleAssignment.find_by!(subject: @member)
    observe_locks do
      delete current_scope.scoped_role_assignment_url(scoped), headers: headers
      assert_response :redirect
    end
  end

  test "role create and update use the same ordered role lock" do
    observe_locks do
      post current_scope.roles_url, params: { role: { name: "New role" } }, headers: headers
      assert_response :redirect
    end
    observe_locks do
      patch current_scope.role_url(@role), params: { role: { name: "Updated role" } }, headers: headers
      assert_response :redirect
    end
  end

  test "programmatic role deletion locks before cascading grants" do
    CurrentScope::RoleAssignment.create!(subject: @member, role: @role)
    observe_locks { @role.destroy! }
    assert_not CurrentScope::RoleAssignment.exists?(subject: @member)
  end

  test "role deletion locks roles before its assignment cascade" do
    CurrentScope::RoleAssignment.create!(subject: @member, role: @role)
    observe_locks do
      delete current_scope.role_url(@role), headers: headers
      assert_response :redirect
    end
    assert_not CurrentScope::RoleAssignment.exists?(subject: @member)
  end
end
