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
end
