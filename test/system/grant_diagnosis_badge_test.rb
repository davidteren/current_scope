require "application_system_test_case"

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
    visit "/current_scope/subjects"

    # Case-insensitive: the badge CSS uppercases it, and Capybara reports the
    # RENDERED text, so a literal match would silently miss a visible badge.
    assert_selector ".cs-dead-badge", text: /cannot match/i
    # Not #90's state, so it must not borrow #90's word.
    assert_no_selector ".cs-inert-badge"
  end

  test "a type mismatch is badged as advisory, not as a verdict" do
    grant(role_with("reports#approve"), @project)
    visit "/current_scope/subjects"

    assert_selector ".cs-check-badge", text: /check hooks/i
    # An unprovable finding must not be rendered as the proven one.
    assert_no_selector ".cs-dead-badge"
  end

  test "a healthy grant carries no diagnosis badge at all" do
    grant(role_with("reports#approve"), @report)
    visit "/current_scope/subjects"

    assert_no_selector ".cs-dead-badge"
    assert_no_selector ".cs-check-badge"
  end

  test "the role members view carries the same badge as the subjects page" do
    role = role_with
    grant(role, @report)
    visit "/current_scope/roles/#{role.id}/members"

    # #90 covers both grant surfaces identically; this must too.
    assert_selector ".cs-dead-badge", text: /cannot match/i
  end
end
