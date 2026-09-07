require "test_helper"

class PermissionScopedRolesTest < ActiveSupport::TestCase
  setup do
    @original = Project.respond_to?(:current_scope_grantable_permissions) ? Project.current_scope_grantable_permissions : nil
    Project.current_scope_grantable_permissions = [ "reports#index", "reports#show" ]
    @role = CurrentScope::Role.create!(name: "Custom viewer", permission_keys: [ "reports#show" ])
    @user = User.create!(name: "Reader")
    @report = Project.create!(name: "Test")
  end

  teardown { Project.current_scope_grantable_permissions = @original if Project.respond_to?(:current_scope_grantable_permissions=) }

  test "custom role names work through scoped assignment and resolver" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    assert CurrentScope.allowed?("reports#show", subject: @user, record: @report)
  end

  test "a grant validates persisted permissions without discarding the caller staged bundle" do
    @role.permission_keys = [ "reports#approve" ]
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
    assert grant.valid?
    assert_equal [ "reports#approve" ], @role.permission_keys
    assert_equal [ "reports#show" ], CurrentScope::Role.find(@role.id).permission_keys
  end

  test "a staged safe bundle cannot disguise an incompatible persisted role" do
    @role.update!(permission_keys: [ "reports#approve" ])
    @role.permission_keys = [ "reports#show" ]
    @role.name = "Staged name"
    grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
    assert_not grant.valid?
    assert_equal [ "reports#show" ], @role.permission_keys
    assert_equal "Staged name", @role.name
  end

  test "permission eligibility accepts existing role names and rejects missing names" do
    assert Project.current_scope_grants_role?(@role.name)
    assert_not Project.current_scope_grants_role?("Missing role")
    @role.update!(permission_keys: [ "reports#approve" ])
    assert_not Project.current_scope_grants_role?(@role.name)
  end

  test "permission and name restrictions combine without widening either" do
    declare_grantable_roles(Project, [ "Different name" ])
    assert_not Project.current_scope_grants_role?(@role)
    declare_grantable_roles(Project, [ @role.name ])
    assert Project.current_scope_grants_role?(@role)
    Project.current_scope_grantable_permissions = []
    assert_not Project.current_scope_grants_role?(@role)
    assert Project.current_scope_locked_down?
  end

  test "mixed and full access bundles are refused" do
    [ { permission_keys: [ "reports#show", "reports#approve" ] }, { full_access: true } ].each do |attributes|
      @role.update!(attributes)
      grant = CurrentScope::ScopedRoleAssignment.new(subject: @user, resource: @report, role: @role)
      assert_not grant.save
      @role.update!(full_access: false, permission_keys: [ "reports#show" ])
    end
  end

  test "removing all permissions leaves existing scoped assignments inert" do
    grant = CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    assert @role.update(permission_keys: [])
    assert CurrentScope::ScopedRoleAssignment.exists?(grant.id)
    assert_not CurrentScope.allowed?("reports#show", subject: @user, record: @report)
  end

  test "editing a held scoped role cannot widen past the resource ceiling" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    assert_not @role.update(permission_keys: [ "reports#show", "reports#approve" ])
    assert_equal [ "reports#show" ], @role.reload.permission_keys
    assert_not @role.update(full_access: true)
    assert_not @role.reload.full_access?
    assert @role.update(name: "Renamed viewer", permission_keys: [ "reports#index", "reports#show" ])
  end
  test "direct permission creation and replacement cannot widen a scoped grant" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    added = @role.role_permissions.build(permission_key: "reports#approve")
    assert_not added.save
    assert_equal [ "reports#show" ], @role.reload.permission_keys
    permission = @role.role_permissions.first
    assert_not permission.update(permission_key: "reports#approve")
    assert_equal "reports#show", permission.reload.permission_key
    assert_not CurrentScope.allowed?("reports#approve", subject: @user, record: @report)
    assert @role.role_permissions.create!(permission_key: "reports#index").persisted?
  end

  test "moving a permission checks the destination role ceiling atomically" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, resource: @report, role: @role)
    source = CurrentScope::Role.create!(name: "Approver", permission_keys: [ "reports#approve" ])
    permission = source.role_permissions.first
    assert_not permission.update(role: @role)
    assert_equal source.id, permission.reload.role_id
    assert_equal [ "reports#show" ], @role.reload.permission_keys
  end
end
