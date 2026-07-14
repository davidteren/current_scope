require "test_helper"

class ManagementUiTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    @member = User.create!(name: "Member")
    @owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @member_role = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    CurrentScope::RoleAssignment.create!(subject: @member, role: @member_role)
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "the management UI is closed to anonymous and non-full-access subjects" do
    get current_scope.roles_url
    assert_response :forbidden

    get current_scope.roles_url, headers: as(@member)
    assert_response :forbidden
  end

  test "a full-access subject can view and edit roles" do
    get current_scope.roles_url, headers: as(@owner)
    assert_response :success

    get current_scope.edit_role_url(@member_role), headers: as(@owner)
    assert_response :success
    # The grid folds index+show into the "read" CRUD group; its checkbox carries
    # the controller:group token.
    assert_match "reports:read", response.body
  end

  test "saving the grid replaces permissions and drops keys not in the catalog" do
    patch current_scope.role_url(@member_role), headers: as(@owner), params: {
      role: { name: "Member", full_access: "0",
              permission_keys: [ "", "reports#index", "bogus#nope" ] }
    }
    assert_redirected_to current_scope.roles_url

    assert_equal [ "reports#index" ], @member_role.reload.permission_keys
  end

  test "setting and clearing a subject's org-wide role" do
    other = User.create!(name: "Other")

    post current_scope.role_assignment_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: @member_role.id }
    assert_equal @member_role, CurrentScope::RoleAssignment.find_by(subject: other).role

    post current_scope.role_assignment_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: "" }
    assert_nil CurrentScope::RoleAssignment.find_by(subject: other)
  end

  test "granting and revoking a scoped role" do
    report = Report.create!(title: "Q3", requested_by: @owner)

    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      subject_gid: @member.to_gid.to_s, resource_gid: report.to_gid.to_s,
      role_id: @member_role.id
    }
    sra = CurrentScope::ScopedRoleAssignment.find_by(subject: @member)
    assert_equal report, sra.resource

    delete current_scope.scoped_role_assignment_url(sra), headers: as(@owner)
    assert_nil CurrentScope::ScopedRoleAssignment.find_by(subject: @member)
  end

  test "refuses to delete the last full-access role" do
    delete current_scope.role_url(@owner_role), headers: as(@owner)
    assert_redirected_to current_scope.roles_url
    assert CurrentScope::Role.exists?(@owner_role.id)

    CurrentScope::Role.create!(name: "SecondOwner", full_access: true)
    delete current_scope.role_url(@owner_role), headers: as(@owner)
    assert_not CurrentScope::Role.exists?(@owner_role.id)
  end

  test "subjects page renders role chips" do
    get current_scope.subjects_url, headers: as(@owner)
    assert_response :success
    assert_match "Owner", response.body
  end
end
