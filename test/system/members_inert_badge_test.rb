require "application_system_test_case"

# #164 — org-wide inert vs deleted on the members page, in a real browser.
class MembersInertBadgeSystemTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    sign_in(@owner)
  end

  test "org-wide holders show inert and deleted as distinct states" do
    role = CurrentScope::Role.create!(name: "Editor")
    now = Time.current
    CurrentScope::RoleAssignment.insert!({
      role_id: role.id,
      subject_type: "token_people_unmapped_164",
      subject_id: "5",
      created_at: now,
      updated_at: now
    })
    inert = CurrentScope::RoleAssignment.find_by!(subject_type: "token_people_unmapped_164")

    ghost = User.create!(name: "Ghost")
    deleted = CurrentScope::RoleAssignment.create!(subject: ghost, role: role)
    ghost.delete

    visit "/current_scope/roles/#{role.id}/members"
    assert_rendered

    assert_selector "#org_holder_#{inert.id}.cs-row--inert"
    assert_selector "#org_holder_#{inert.id} .cs-inert-badge", text: /inert/i
    assert_selector "#org_remove_#{inert.id}", text: /Remove inert/i

    assert_selector "#org_holder_#{deleted.id}", text: /subject deleted/
    assert_no_selector "#org_holder_#{deleted.id} .cs-inert-badge"

    find("[data-cs-theme-toggle]").click
    assert_selector "#org_holder_#{inert.id} .cs-inert-badge", text: /inert/i
  end
end
