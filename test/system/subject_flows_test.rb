require "application_system_test_case"

# Subjects page interactive flows: multi-select + bulk org-role assignment (the
# JS injects the checked subjects into the POST form), pagination, and that a
# mutation shows up in the events ledger.
class SubjectFlowsSystemTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    sign_in(@owner)
  end

  test "multi-select + bulk org-role sets the role for exactly the checked subjects" do
    alice = User.create!(name: "Alice Adams")
    bob = User.create!(name: "Bob Brown")
    role = CurrentScope::Role.create!(name: "Reviewer")

    visit "/current_scope/subjects"
    find("tr", text: "Alice Adams").find("[data-cs-select]").check
    find("tr", text: "Bob Brown").find("[data-cs-select]").check

    within "[data-cs-bulk]" do
      assert_text "2 selected"
      select "Reviewer", from: "role_id"
      click_button "Set for selected"
    end

    assert_text "Org-wide role set"
    assert_equal role, CurrentScope::RoleAssignment.find_by(subject: alice)&.role
    assert_equal role, CurrentScope::RoleAssignment.find_by(subject: bob)&.role
    # Olivia (unchecked) keeps her Owner role.
    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: @owner).role.name
  end

  test "a selected subject stays visible and selected when a filter would hide it" do
    alice = User.create!(name: "Alice Adams")
    User.create!(name: "Bob Brown")
    visit "/current_scope/subjects"
    find("tr", text: "Alice Adams").find("[data-cs-select]").check

    find("[data-cs-filter]").set("Bob") # would hide Alice, but she's selected

    assert_selector "tr[data-cs-row]:not([hidden])", text: "Alice Adams"
    within "[data-cs-bulk]" do
      assert_text "1 selected" # Alice is still counted, not silently dropped
    end
  end

  test "the bulk bar is hidden until a subject is selected" do
    User.create!(name: "Someone Else")
    visit "/current_scope/subjects"
    assert_no_selector "[data-cs-bulk]:not([hidden])"
    find("tr", text: "Someone Else").find("[data-cs-select]").check
    assert_selector "[data-cs-bulk]:not([hidden])"
  end

  # #90 — orphaned scoped grant UI in a real browser (layout + CSS).
  test "orphaned scoped grant shows inert badge on subjects" do
    alice = User.create!(name: "Alice Adams")
    folder = Folder.create!(name: "Doomed Space")
    role = CurrentScope::Role.create!(name: "Space Editor")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: folder, role: role)
    folder.destroy!

    visit "/current_scope/subjects"
    assert_selector "#scoped_chip_#{sra.id}.cs-chip--inert"
    assert_text "unavailable — inert"
    # CSS text-transform: uppercase → visible text is "INERT"
    assert_selector ".cs-inert-badge", text: /inert/i
  end

  test "server-side search finds a subject that isn't on the current page" do
    55.times { |i| User.create!(name: "Filler #{format('%02d', i)}") } # push the target off page 1
    User.create!(name: "Deep Cut Persson")

    visit "/current_scope/subjects"
    assert_no_text "Deep Cut Persson" # not on the first page
    fill_in "q", with: "Deep Cut"
    click_button "Search"
    assert_text "Deep Cut Persson" # server search reached it
  end

  test "subjects paginate past the page size" do
    55.times { |i| User.create!(name: "Bulk User #{format('%02d', i)}") } # + owner > PER_PAGE(50)
    visit "/current_scope/subjects"
    assert_text "Page 1"
    click_link "Next →"
    assert_text "Page 2"
    assert_rendered
  end

  test "a mutation is recorded in the events ledger" do
    visit "/current_scope/roles/new"
    fill_in "role_name", with: "Freshly Made"
    click_button "Create role"
    assert_text "Role created."

    visit "/current_scope/events"
    assert_rendered
    assert_text "role.created"
    assert_text "Freshly Made"
  end
end
