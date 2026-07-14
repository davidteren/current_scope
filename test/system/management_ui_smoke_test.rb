require "application_system_test_case"

# Renders every mounted management-UI page in a real browser with realistic data,
# so a template error (the kind unit tests with assert_select can miss under a
# stale reload) or a broken layout surfaces. Also drops screenshots under
# tmp/screenshots for visual review.
class ManagementUiSmokeTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))

    # A couple of editable roles + members, a folder scoped grant, and some
    # subjects, so the grid, subjects, and members pages have real content.
    @editor = CurrentScope::Role.create!(name: "Editor", description: "Edits and approves reports")
    @editor.role_permissions.create!(permission_key: "reports#index")
    @editor.role_permissions.create!(permission_key: "documents#index")
    @editor.role_permissions.create!(permission_key: "documents#show")

    @alice = User.create!(name: "Alice Adams")
    @bob = User.create!(name: "Bob Brown")
    CurrentScope::RoleAssignment.create!(subject: @alice, role: @editor)
    folder = Folder.create!(name: "Q3 Planning")
    CurrentScope::ScopedRoleAssignment.create!(subject: @bob, resource: folder, role: @editor)

    sign_in(@owner)
  end

  test "roles index renders" do
    visit "/current_scope/roles"
    assert_rendered
    assert_text "Editor"
    shot("roles-index")
  end

  test "role edit / permission grid renders" do
    visit "/current_scope/roles/#{@editor.id}/edit"
    assert_rendered
    assert_text "Permission grid"
    assert_selector "table.cs-grid"
    # Regression guard: the sticky column header must not paint over the first
    # data row. Its sticky containing block is .cs-grid-wrap (overflow-x), so any
    # positive `top` offset pushes it down onto the first row.
    overlaps = page.evaluate_script(<<~JS)
      (() => {
        const th = document.querySelector('.cs-grid thead th');
        const firstRow = document.querySelector('.cs-grid tbody tr:first-child th[scope="row"]');
        return th.getBoundingClientRect().bottom > firstRow.getBoundingClientRect().top + 1;
      })()
    JS
    assert_not overlaps, "the grid header is overlapping the first controller row"
    shot("role-edit-grid")             # viewport, unscrolled
    page.execute_script("window.scrollBy(0, 520)")
    shot("role-edit-grid-scrolled")    # sticky header under the topbar while scrolled
  end

  test "role members renders" do
    visit "/current_scope/roles/#{@editor.id}/members"
    assert_rendered
    assert_text "Members: Editor"
    assert_text "Alice Adams" # org-wide holder
    assert_text "Bob Brown"   # scoped holder
    shot("role-members")
  end

  test "subjects index renders" do
    visit "/current_scope/subjects"
    assert_rendered
    assert_text "Alice Adams"
    shot("subjects-index")
  end

  test "events index renders" do
    visit "/current_scope/events"
    assert_rendered
    shot("events-index")
  end
end
