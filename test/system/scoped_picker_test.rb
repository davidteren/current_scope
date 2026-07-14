require "application_system_test_case"

# The guided scoped-role picker: Role -> Subject -> Resource type -> Record. Each
# control autosubmits (full-page GET here, since the dummy loads no Turbo) to
# re-render the next step. Drives the whole cascade to a real grant.
class ScopedPickerSystemTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    sign_in(@owner)
  end

  test "the cascade grants a scoped role on the chosen record" do
    role = CurrentScope::Role.create!(name: "Folder Editor")
    pat = User.create!(name: "Pat Picker")
    folder = Folder.create!(name: "Shared Space")

    visit "/current_scope/scoped_role_assignments/new"
    select "Folder Editor", from: "role_id"      # autosubmit -> reload
    select "Pat Picker", from: "subject_gid"     # autosubmit -> reload
    select "Folder", from: "resource_type"       # autosubmit -> reload (records appear)
    select "Shared Space", from: "resource_gid"  # autosubmit -> reload (grant button appears)
    click_button "Grant scoped role"

    assert_text "Scoped role granted"
    assert CurrentScope::ScopedRoleAssignment.exists?(subject: pat, resource: folder, role: role),
      "the cascade did not create the scoped assignment"
  end
end
