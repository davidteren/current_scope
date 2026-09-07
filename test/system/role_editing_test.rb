require "application_system_test_case"

# The role editor driven in a real browser — the grid JS (group checkboxes,
# per-row master, the partial-grant escalation guard) only behaves under real
# JS, so unit tests can't prove these end to end.
class RoleEditingSystemTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    sign_in(@owner)
  end

  test "delegated administrator creates a role while full access stays unavailable" do
    prior = CurrentScope.config.management_authorizer
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, target: nil) do
      subject == @owner && (!role || !role.full_access?)
    end
    visit "/current_scope/roles"
    owner_role = CurrentScope::Role.find_by!(name: "Owner")
    assert_selector "#cs_delete_role_#{owner_role.id}[disabled][aria-describedby='cs_delete_role_#{owner_role.id}_limit']"
    assert_selector "#cs_delete_role_#{owner_role.id}_limit",
      text: "Your administration permissions do not allow deletion of this role."
    click_link "cs_new_role"
    assert_selector "#role_full_access[disabled]"
    fill_in "role_name", with: "Delegated custom role"
    click_button "Create role"
    assert_selector "#role_name[value='Delegated custom role']"
    assert_selector "#role_full_access[disabled]"
    visit "/current_scope/roles/#{CurrentScope::Role.find_by!(name: 'Owner').id}/edit"
    assert_equal 403, page.status_code
    assert_selector "#cs_management_denied", text: "This action is not permitted"
  ensure
    CurrentScope.config.management_authorizer = prior
  end

  test "a create-only administrator lands on the role list with a success notice" do
    prior = CurrentScope.config.management_authorizer
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, **) do
      subject == @owner && %i[access create_role].include?(action) && (!role || !role.full_access?)
    end
    visit "/current_scope/roles/new"
    fill_in "role_name", with: "Create-only browser role"
    click_button "Create role"

    assert_selector ".cs-flash--notice", text: "Role created."
    assert_current_path "/current_scope/roles"
    assert_text "Create-only browser role"
    assert CurrentScope::Role.exists?(name: "Create-only browser role")
  ensure
    CurrentScope.config.management_authorizer = prior
  end

  test "the full-access label states the non-cascade carve-out, on both forms" do
    # Asserted in a real browser, not by reading the ERB: the claim is about what
    # an operator SEES before ticking a box that no longer means what it used to.
    # KTD-2 made "every permission, present and future" false for a declared
    # chain, and this label is the only place the console says so.
    role = CurrentScope::Role.create!(name: "Labelled")

    [ "/current_scope/roles/new", "/current_scope/roles/#{role.id}/edit" ].each do |path|
      visit path

      assert page.has_text?("Does not cascade to child records through current_scope_parent"),
             "#{path} must show the full_access carve-out"
    end
  end

  test "creating a role with a blank name shows a validation error, not a crash" do
    visit "/current_scope/roles/new"
    fill_in "role_name", with: ""
    click_button "Create role"
    # A validation error re-renders the form at 422 (not a 500) with the message.
    assert_equal 422, page.status_code
    assert_text "Name can't be blank"
    assert_selector "form" # still on the form, not an error page
  end

  test "ticking a CRUD group in the grid grants its routed actions" do
    role = CurrentScope::Role.create!(name: "Doc Reader")
    visit "/current_scope/roles/#{role.id}/edit"
    check "perm_documents_read"
    click_button "Save role"
    assert_text "Role updated."
    keys = role.reload.permission_keys
    assert_includes keys, "documents#index"
    assert_includes keys, "documents#show"
  end

  test "a partial group renders unchecked + indeterminate and re-saving does not broaden it" do
    role = CurrentScope::Role.create!(name: "Partial Reader")
    role.role_permissions.create!(permission_key: "documents#index") # read = index only
    visit "/current_scope/roles/#{role.id}/edit"

    assert_selector "#perm_documents_read[data-cs-partial='true']"
    state = page.evaluate_script("(()=>{const b=document.getElementById('perm_documents_read');return {checked:b.checked, indeterminate:b.indeterminate};})()")
    assert_not state["checked"], "a partial group must render unchecked (checked would promote it on save)"
    assert state["indeterminate"], "a partial group should show as indeterminate"

    click_button "Save role" # untouched
    keys = role.reload.permission_keys
    assert_includes keys, "documents#index"
    assert_not_includes keys, "documents#show", "re-saving silently broadened a partial grant"
  end

  test "the per-row master grants every action in its controller" do
    role = CurrentScope::Role.create!(name: "Doc Admin")
    visit "/current_scope/roles/#{role.id}/edit"
    find("input[data-cs-row-all][aria-label='Enable all documents permissions']").check
    click_button "Save role"
    keys = role.reload.permission_keys
    %w[documents#index documents#show documents#new documents#create
       documents#edit documents#update documents#destroy].each do |key|
      assert_includes keys, key
    end
  end
  test "a refused bundle edit keeps the draft and can be corrected" do
    prior = CurrentScope.config.management_authorizer
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, **) do
      subject == @owner && (!role || (!role.full_access? && (role.permission_keys - [ "reports#index" ]).empty?))
    end
    role = CurrentScope::Role.create!(name: "Limited reader", permission_keys: [ "reports#index" ])
    visit "/current_scope/roles/#{role.id}/edit"
    fill_in "role_name", with: "Revised reader"
    fill_in "role_description", with: "Read reports for the team."
    check "perm_reports_approve"
    click_button "Save role"

    assert_selector "#cs_role_errors", text: "permission limit"
    assert_field "role_name", with: "Revised reader"
    assert_field "role_description", with: "Read reports for the team."
    assert_checked_field "perm_reports_approve"
    assert_equal "Limited reader", role.reload.name
    assert_equal [ "reports#index" ], role.permission_keys

    uncheck "perm_reports_approve"
    click_button "Save role"
    assert_selector "#cs_new_role"
    assert_equal "Revised reader", role.reload.name
    assert_equal "Read reports for the team.", role.description
    assert_equal [ "reports#index" ], role.permission_keys
  ensure
    CurrentScope.config.management_authorizer = prior
  end

  test "a refused role creation keeps its draft and can be corrected" do
    prior = CurrentScope.config.management_authorizer
    CurrentScope.config.management_authorizer = ->(subject, action:, role: nil, **) do
      subject == @owner && (!role || (!role.full_access? && role.name != "New team reader"))
    end
    visit "/current_scope/roles/new"
    fill_in "role_name", with: "New team reader"
    fill_in "role_description", with: "Read reports for the team."
    click_button "Create role"

    assert_selector "#cs_role_errors", text: "permission limit"
    assert_field "role_name", with: "New team reader"
    assert_field "role_description", with: "Read reports for the team."
    assert_unchecked_field "role_full_access", disabled: true
    assert_not CurrentScope::Role.exists?(name: "New team reader")

    fill_in "role_name", with: "Corrected team reader"
    click_button "Create role"
    assert_field "role_name", with: "Corrected team reader"
    role = CurrentScope::Role.find_by!(name: "Corrected team reader")
    assert_equal "Read reports for the team.", role.description
    assert_empty role.permission_keys
  ensure
    CurrentScope.config.management_authorizer = prior
  end
end
