require "test_helper"

# The role editor's aligned CRUD grid: fixed columns, grouped checkboxes that
# grant the underlying routed actions.
class RoleGridTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @role = CurrentScope::Role.create!(name: "Editor")
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "the grid renders fixed CRUD column headers" do
    get current_scope.edit_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "thead th", text: "read"
    assert_select "thead th", text: "create"
    assert_select "thead th", text: "update"
    assert_select "thead th", text: "destroy"
    # Columns are absolute: every body row renders one sticky header + one cell
    # per column (blanks included), so the first row's child count is aligned.
    columns = CurrentScope::PermissionGrid.new.columns.size
    assert_select "tbody tr:first-child > *", count: columns + 1
  end

  test "ticking a CRUD group grants every routed action in it" do
    # reports routes index + show; the "read" group should grant both.
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", full_access: "0", permission_groups: [ "reports:read" ] } }
    assert_redirected_to current_scope.roles_path

    keys = @role.reload.permission_keys
    assert_includes keys, "reports#index"
    assert_includes keys, "reports#show"
  end

  test "a role carries an optional description" do
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", description: "May edit and approve reports", full_access: "0" } }
    assert_equal "May edit and approve reports", @role.reload.description

    get current_scope.roles_url, headers: as(@owner)
    assert_select ".cs-subtle", text: "May edit and approve reports"
  end

  test "raw permission_keys still work alongside the group channel" do
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", full_access: "0",
                            permission_keys: [ "reports#approve" ],
                            permission_groups: [ "reports:read" ] } }
    keys = @role.reload.permission_keys
    assert_includes keys, "reports#approve"
    assert_includes keys, "reports#index"
  end
end
