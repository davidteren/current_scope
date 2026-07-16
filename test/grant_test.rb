require "test_helper"

# A11: CurrentScope.grant! bootstraps the first admin (backs the
# current_scope:grant rake task), so the initial full_access assignment isn't a
# bare console step.
class GrantTest < ActiveSupport::TestCase
  setup { @user = User.create!(name: "First Admin") }

  test "grants the full-access Owner role as the subject's org-wide role" do
    CurrentScope.grant!(@user)

    role = CurrentScope::RoleAssignment.find_by(subject: @user)&.role
    assert role, "expected an org-wide role assignment"
    assert_equal "Owner", role.name
    assert role.full_access?
    assert CurrentScope.resolver.full_access?(@user)
  end

  test "is idempotent — re-running does not duplicate the assignment" do
    CurrentScope.grant!(@user)
    assert_no_difference -> { CurrentScope::RoleAssignment.where(subject: @user).count } do
      CurrentScope.grant!(@user)
    end
  end

  test "upgrades an existing non-owner subject to Owner" do
    member = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @user, role: member)

    CurrentScope.grant!(@user)

    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: @user).role.name
  end

  # grant! promises "assign a role" — passing an explicit role must not ALSO
  # create a full-access Owner (and a Member) in the roles table as a side
  # effect. Seeding belongs to the default path only.
  test "granting an explicit role seeds no default roles" do
    custom = CurrentScope::Role.create!(name: "Custom")

    assert_no_difference -> { CurrentScope::Role.count } do
      CurrentScope.grant!(@user, role: custom)
    end

    assert_equal custom, CurrentScope::RoleAssignment.find_by(subject: @user).role
    assert_not CurrentScope::Role.exists?(name: "Owner"),
               "no full-access Owner may appear as a side effect of an explicit grant"
  end
end
