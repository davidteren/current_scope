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

  # #183 in a real browser: the ROLE is picked first, so it is the type list that
  # narrows. The states this feature added are conditional renders, which a
  # layout-less request test can miss.
  test "picking a role narrows the type list, and picking another brings it back" do
    # Gadget: autoloading it registers a SECOND type, so the page shows the type
    # step rather than "no type accepts this role", whatever the test order.
    Gadget
    CurrentScope::Role.create!(name: "Folder Editor")
    CurrentScope::Role.create!(name: "Vault Keeper")
    Folder.create!(name: "Shared Space")
    declare_grantable_roles(Folder, [ "Folder Editor" ])

    visit "/current_scope/scoped_role_assignments/new"
    # No role is applied yet, so nothing is filtered and nothing is claimed.
    assert_no_selector "#cs_types_withheld"
    assert_selector "#resource_type option[value='Folder']"

    select "Vault Keeper", from: "role_id"
    assert_selector "#cs_types_withheld"
    # A type that does not accept the chosen role must not be offered.
    assert_no_selector "#resource_type option[value='Folder']"

    select "Folder Editor", from: "role_id"
    assert_no_selector "#cs_types_withheld"
    assert_selector "#resource_type option[value='Folder']"
  end

  # The record step, in the browser: a type whose records refuse the role says so
  # where the list would be, and offers no Grant button.
  test "a record list emptied by the role filter explains itself" do
    Gadget # autoload ⇒ a second registered type (see above)
    CurrentScope::Role.create!(name: "Vault Keeper")
    User.create!(name: "Pat Picker")
    Folder.create!(name: "Shared Space")
    declare_grantable_roles(Folder, [ "Vault Keeper" ])

    visit "/current_scope/scoped_role_assignments/new"
    select "Vault Keeper", from: "role_id"
    select "Pat Picker", from: "subject_gid"
    select "Folder", from: "resource_type"
    assert_selector "#resource_gid option[value*='Folder']"

    # Now the same type under a role it does not accept: the Grant path closes.
    select "Owner", from: "role_id"
    assert_no_selector ".cs-btn-primary"
    assert_selector "#cs_types_withheld"
  end
end
