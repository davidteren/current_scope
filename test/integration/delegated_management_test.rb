require "test_helper"

class DelegatedManagementTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "Delegated administrator")
    @member = User.create!(name: "Member")
    @role = CurrentScope::Role.create!(name: "Editable", permission_keys: [ "reports#index" ])
    @protected = CurrentScope::Role.create!(name: "Protected", full_access: true)
    @original_authorizer = CurrentScope.config.respond_to?(:management_authorizer) ? CurrentScope.config.management_authorizer : nil
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, target: nil) do
      subject == @admin && (!role || (!role.full_access? && (role.permission_keys - [ "reports#index" ]).empty?)) && target != @admin
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

  test "forged candidate cannot exceed the permission ceiling" do
    patch current_scope.role_url(@role), params: { role: { permission_keys: [ "reports#approve" ] } }, headers: headers
    assert_response :forbidden
    assert_equal [ "reports#index" ], @role.reload.permission_keys
    assert_equal "management_denied", response.headers["X-Current-Scope-Reason"]
    assert_select "#cs_management_denied", text: "This action is not permitted"
    assert_includes response.body, "permission limit"
    assert_not_includes response.body, "This area needs a full-access role"
  end

  test "a protected old bundle cannot be replaced by an allowed candidate" do
    patch current_scope.role_url(@protected), params: { role: { name: "Editable now", full_access: false, permission_keys: [ "reports#index" ] } }, headers: headers
    assert_response :forbidden
    assert @protected.reload.full_access?
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
end
