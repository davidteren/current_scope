require "application_system_test_case"

# U3 of plan 032 (#134). Role MEMBERS view only — see the note in the PR: the
# subjects page badge is deferred because it widened that table past the
# viewport at narrow widths and broke the overflow guard from PR #11.
#
# U3 of plan 032 (#134). The console must let an operator tell THREE states
# apart, because each has a different fix:
#
#   inert (#90)   the record is gone            → remove the grant
#   cannot match  the role reaches nothing      → tick a key
#   check hooks   advisory, not a verdict       → look at current_scope_record
#
# Reusing #90's "inert" for any of these would send an operator to the wrong
# remedy, which is why the wording is asserted here and not just the CSS class.
class GrantDiagnosisBadgeSystemTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    sign_in(@owner)
    @holder = User.create!(name: "Holder")
    @report = Report.create!(title: "Q3", requested_by: @holder)
    @project = Project.create!(name: "P7")
  end

  def role_with(*keys)
    r = CurrentScope::Role.create!(name: "R-#{rand(10**9)}")
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def grant(role, resource)
    CurrentScope::ScopedRoleAssignment.create!(subject: @holder, role: role, resource: resource)
  end

  test "a grant whose role ticks nothing is badged 'cannot match', not 'inert'" do
    grant(role_with, @report)
    visit "/current_scope/roles/#{CurrentScope::ScopedRoleAssignment.last.role_id}/members"

    # Case-insensitive: the CSS uppercases it and Capybara reads rendered text.
    assert_selector ".cs-dead-badge", text: /cannot match/i
    # Not #90's state, so it must not borrow #90's word.
    assert_no_selector ".cs-inert-badge"
  end

  test "a type mismatch is badged as advisory, not as a verdict" do
    # Folder, not Project: since #108 a Report-keyed role on a Project is a
    # WORKING parent-chain grant and must not be flagged at all.
    grant(role_with("reports#approve"), Folder.create!(name: "F"))
    visit "/current_scope/roles/#{CurrentScope::ScopedRoleAssignment.last.role_id}/members"

    assert_selector ".cs-check-badge", text: /check hooks/i
    # An unprovable finding must not be rendered as the proven one.
    assert_no_selector ".cs-dead-badge"
  end

  test "a healthy grant carries no diagnosis badge at all" do
    grant(role_with("reports#approve"), @report)
    visit "/current_scope/roles/#{CurrentScope::ScopedRoleAssignment.last.role_id}/members"

    assert_no_selector ".cs-dead-badge"
    assert_no_selector ".cs-check-badge"
  end
end
