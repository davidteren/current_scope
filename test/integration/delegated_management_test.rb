require "test_helper"

class DelegatedManagementTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "Delegated administrator")
    @member = User.create!(name: "Member")
    @role = CurrentScope::Role.create!(name: "Editable", permission_keys: [ "reports#index" ])
    @protected = CurrentScope::Role.create!(name: "Protected", full_access: true)
    @original_authorizer = CurrentScope.config.respond_to?(:management_authorizer) ? CurrentScope.config.management_authorizer : nil
    @management_calls = []
    @allowed_actions = %i[access create_role update_role destroy_role assign_role revoke_role assign_scoped_role revoke_scoped_role]
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, target: nil) do
      @management_calls << [ action, role&.name, role&.permission_keys, target ]
      @allowed_actions.include?(action) && subject == @admin && (!role || (!role.full_access? && (role.permission_keys - [ "reports#index" ]).empty?)) && target != @admin
    end
  end

  teardown { CurrentScope.config.management_authorizer = @original_authorizer if CurrentScope.config.respond_to?(:management_authorizer=) }

  def headers = { "X-User-Id" => @admin.id.to_s }

  test "delegated administrator creates and edits permitted bundles" do
    get current_scope.roles_url, headers: headers
    assert_response :success
    post current_scope.roles_url, params: { role: { name: "Custom", permission_keys: [ "reports#index" ] } }, headers: headers
    assert_response :redirect
    role = CurrentScope::Role.find_by!(name: "Custom")
    patch current_scope.role_url(role), params: { role: { name: "Renamed", permission_keys: [ "reports#index" ] } }, headers: headers
    assert_response :redirect
    assert_equal "Renamed", role.reload.name
  end

  test "full access checkbox and update preserve the role identity passed to policy" do
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, **) do
      subject == @admin && (action == :access ||
        (action == :update_role && role&.persisted? && role.id == @role.id))
    end
    get current_scope.edit_role_url(@role), headers: headers
    assert_response :success
    assert_select "#role_full_access:not([disabled])", count: 1
    assert_not @role.reload.full_access?

    patch current_scope.role_url(@role), params: { role: { full_access: true, permission_keys: [ "reports#index" ] } }, headers: headers
    assert_response :redirect
    assert @role.reload.full_access?
  end

  test "a refused candidate preserves the edit form without exceeding the permission ceiling" do
    patch current_scope.role_url(@role), params: { role: { name: "Draft name", description: "Draft description", permission_keys: [ "reports#approve" ] } }, headers: headers
    assert_response :forbidden
    assert_equal [ "reports#index" ], @role.reload.permission_keys
    assert_equal "management_denied", response.headers["X-Current-Scope-Reason"]
    assert_select "#cs_role_errors", text: /permission limit/
    assert_select "#role_name[value=?]", "Draft name"
    assert_select "#role_description", text: "Draft description"
    assert_select "#perm_reports_approve[checked]"
    assert_includes response.body, "permission limit"
    assert_not_includes response.body, "This area needs a full-access role"
  end

  test "a refused create preserves its draft only for HTML after console entry" do
    original = CurrentScope.config.management_authorizer
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, **options) do
      original.call(subject, action: action, role: role, **options) && role&.name != "New draft"
    end
    submitted = { role: { name: "New draft", description: "Draft description", full_access: false } }
    assert_no_difference("CurrentScope::Role.count") do
      post current_scope.roles_url, params: submitted, headers: headers
    end
    assert_response :forbidden
    assert_equal "management_denied", response.headers["X-Current-Scope-Reason"]
    assert_select "#cs_role_errors", text: /permission limit/
    assert_select "#role_name[value=?]", "New draft"
    assert_select "#role_description", text: "Draft description"
    assert_select "#role_full_access:not([checked])"
    assert_select "form[action=?]", current_scope.roles_path

    post current_scope.roles_url, params: submitted, headers: headers.merge("Accept" => "application/json")
    assert_response :forbidden
    assert_equal "management_denied", response.headers["X-Current-Scope-Reason"]
    assert_empty response.body

    @allowed_actions.delete(:access)
    post current_scope.roles_url, params: submitted, headers: headers
    assert_response :forbidden
    assert_select "#cs_management_denied"
    assert_select "#role_name", count: 0
    assert_not CurrentScope::Role.exists?(name: "New draft")
  end

  test "a protected old bundle cannot be replaced by an allowed candidate" do
    patch current_scope.role_url(@protected), params: { role: { name: "Editable now", full_access: false, permission_keys: [ "reports#index" ] } }, headers: headers
    assert_response :forbidden
    assert @protected.reload.full_access?
    assert_select "#cs_management_denied"
    assert_select "#role_name", count: 0
  end

  test "a non-HTML candidate refusal stays bodyless with the denial reason" do
    patch current_scope.role_url(@role), params: { role: { permission_keys: [ "reports#approve" ] } },
      headers: headers.merge("Accept" => "application/json")
    assert_response :forbidden
    assert_equal "management_denied", response.headers["X-Current-Scope-Reason"]
    assert_empty response.body
    assert_equal [ "reports#index" ], @role.reload.permission_keys
  end

  test "deletion and assignment cannot affect protected bundles" do
    delete current_scope.role_url(@protected), headers: headers
    assert_response :forbidden
    assert CurrentScope::Role.exists?(@protected.id)
    post current_scope.role_assignments_url, params: { subject_gid: @member.to_gid.to_s, role_id: @protected.id }, headers: headers
    assert_response :forbidden
    CurrentScope::RoleAssignment.create!(subject: @member, role: @protected)
    post current_scope.role_assignments_url, params: { subject_gid: @member.to_gid.to_s, role_id: @role.id }, headers: headers
    assert_response :forbidden
    assert_equal @protected, CurrentScope::RoleAssignment.find_by!(subject: @member).role
  end

  test "scoped grants and revocations check every target" do
    project = Project.create!(name: "Project")
    post current_scope.scoped_role_assignments_url, params: { resource_gid: project.to_gid.to_s, subject_gids: [ @member.to_gid.to_s, @admin.to_gid.to_s ], role_id: @role.id }, headers: headers
    assert_response :forbidden
    assert_equal 0, CurrentScope::ScopedRoleAssignment.count
    assignment = CurrentScope::ScopedRoleAssignment.create!(subject: @admin, resource: project, role: @role)
    delete current_scope.scoped_role_assignment_url(assignment), headers: headers
    assert_response :forbidden
    assert CurrentScope::ScopedRoleAssignment.exists?(assignment.id)
  end

  test "bulk assignment rolls back when any target is forbidden" do
    post current_scope.role_assignments_url, params: { subject_gids: [ @member.to_gid.to_s, @admin.to_gid.to_s ], role_id: @role.id }, headers: headers
    assert_response :forbidden
    assert_equal 0, CurrentScope::RoleAssignment.where(role: @role).count
  end
  test "each write requires its specific management action" do
    project = Project.create!(name: "Project")
    expect_action(:create_role) do
      post current_scope.roles_url, params: { role: { name: "Action role", permission_keys: [ "reports#index" ] } }, headers: headers
    end
    role = CurrentScope::Role.find_by!(name: "Action role")
    expect_action(:update_role) do
      patch current_scope.role_url(role), params: { role: { name: "Changed action role", permission_keys: [] } }, headers: headers
    end
    updates = @management_calls.select { |call| call.first == :update_role }
    assert_includes updates.map { |call| call[1..2] }, [ "Action role", [ "reports#index" ] ]
    assert_includes updates.map { |call| call[1..2] }, [ "Changed action role", [] ]
    expect_action(:assign_role) do
      post current_scope.role_assignments_url, params: { subject_gid: @member.to_gid.to_s, role_id: role.id }, headers: headers
    end
    expect_action(:revoke_role) do
      post current_scope.role_assignments_url, params: { subject_gid: @member.to_gid.to_s, role_id: @role.id }, headers: headers
    end
    assert_equal @role, CurrentScope::RoleAssignment.find_by!(subject: @member).role
    org = CurrentScope::RoleAssignment.find_by!(subject: @member)
    expect_action(:revoke_role) { delete current_scope.role_assignment_url(org), headers: headers }
    expect_action(:assign_scoped_role) do
      post current_scope.scoped_role_assignments_url, params: { subject_gid: @member.to_gid.to_s, resource_gid: project.to_gid.to_s, role_id: @role.id }, headers: headers
    end
    scoped = CurrentScope::ScopedRoleAssignment.find_by!(subject: @member)
    expect_action(:revoke_scoped_role) { delete current_scope.scoped_role_assignment_url(scoped), headers: headers }
    expect_action(:destroy_role) { delete current_scope.role_url(role), headers: headers }
  end

  private

  def expect_action(action)
    @allowed_actions.delete(action)
    @management_calls.clear
    yield
    assert_response :forbidden
    assert_includes @management_calls.map(&:first), action
    @allowed_actions << action
    @management_calls.clear
    yield
    assert_response :redirect
    assert_includes @management_calls.map(&:first), action
  end
end
