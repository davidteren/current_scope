require "application_system_test_case"

# A scoped grant the type would now refuse still matches until someone revokes
# it. The console must say that on Members and on Subjects, beside any
# diagnosis badge, and must not revoke the row by rendering it.
class DeclarationRefusedBadgeSystemTest < ApplicationSystemTestCase
  CAVEAT =
    "The type's declaration would refuse this role if it were granted today, " \
    "and the existing grant still matches until someone revokes it."

  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    sign_in(@owner)
    @holder = User.create!(name: "Holder")
  end

  def role_named(name, *keys)
    role = CurrentScope::Role.create!(name: name)
    keys.each { |key| role.role_permissions.create!(permission_key: key) }
    role
  end

  def grant(role, resource)
    CurrentScope::ScopedRoleAssignment.create!(subject: @holder, role: role, resource: resource)
  end

  def assert_refusal_badge(assignment)
    badge = find("#declaration_refused_#{assignment.id}")
    assert_match(/would refuse/i, badge.text)
    assert_includes badge[:class], "cs-declaration-badge"
    assert_equal CAVEAT, badge[:title]
    note = badge.find(".cs-badge-note", visible: :all)
    assert_equal "— #{CAVEAT}", note.text(:all).strip
    assert CurrentScope::ScopedRoleAssignment.exists?(assignment.id)
  end

  test "a grant the declaration refuses is badged on members and on subjects, and is not revoked" do
    project = Project.create!(name: "P1")
    assignment = grant(role_named("Site Editor", "reports#show"), project)
    declare_grantable_roles(Project, [ "Project Lead" ])

    visit "/current_scope/roles/#{assignment.role_id}/members"
    within "#scoped_holder_#{assignment.id}" do
      assert_refusal_badge(assignment)
      assert_selector "#scoped_revoke_#{assignment.id}"
    end

    visit "/current_scope/subjects"
    within "#scoped_chip_#{assignment.id}" do
      assert_refusal_badge(assignment)
      assert_selector "#scoped_chip_revoke_#{assignment.id}"
    end
  end

  test "an orphan shows no declaration badge" do
    project = Project.create!(name: "Gone")
    assignment = grant(role_named("Site Editor"), project)
    declare_grantable_roles(Project, [ "Project Lead" ])
    project.destroy!

    visit "/current_scope/roles/#{assignment.role_id}/members"
    assert_no_selector "#declaration_refused_#{assignment.id}"

    visit "/current_scope/subjects"
    assert_no_selector "#declaration_refused_#{assignment.id}"
  end

  test "a conforming grant shows no declaration badge" do
    project = Project.create!(name: "P2")
    assignment = grant(role_named("Project Lead", "reports#show"), project)
    declare_grantable_roles(Project, [ "Project Lead" ])

    visit "/current_scope/roles/#{assignment.role_id}/members"
    assert_no_selector "#declaration_refused_#{assignment.id}"
    assert_no_selector ".cs-declaration-badge"

    visit "/current_scope/subjects"
    assert_no_selector "#declaration_refused_#{assignment.id}"
    assert_no_selector ".cs-declaration-badge"
  end

  test "a row can show a diagnosis badge and a declaration badge together" do
    project = Project.create!(name: "P3")
    assignment = grant(role_named("Bare Role"), project)
    declare_grantable_roles(Project, [ "Project Lead" ])

    visit "/current_scope/roles/#{assignment.role_id}/members"
    within "#scoped_holder_#{assignment.id}" do
      assert_selector ".cs-dead-badge", text: /cannot match/i
      assert_refusal_badge(assignment)
      assert_selector "#scoped_revoke_#{assignment.id}"
    end
  end
end
