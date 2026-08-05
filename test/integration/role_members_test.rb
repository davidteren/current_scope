require "test_helper"

# The role-side members view: who holds a role (org-wide + scoped), and adding
# org-wide members from the role rather than the subject.
class RoleMembersTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @role = CurrentScope::Role.create!(name: "Editor")
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "members lists org-wide and scoped holders and offers non-holders to add" do
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")
    folder = Folder.create!(name: "Space")
    CurrentScope::RoleAssignment.create!(subject: alice, role: @role)
    CurrentScope::ScopedRoleAssignment.create!(subject: bob, resource: folder, role: @role)

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "h1", text: "Members: Editor"
    assert_select "td", text: "Alice"          # org-wide holder
    assert_select "td", text: "Bob"            # scoped holder
    # Alice already holds it org-wide -> not offered; Bob (scoped only) is.
    assert_select "select[name='subject_gids[]'] option", text: "Bob"
    assert_select "select[name='subject_gids[]'] option", { text: "Alice", count: 0 }
  end

  # The candidate query is the ONE place #151 left adapter-specific SQL: it casts
  # the subject's primary key to text so a varchar subject_id can be compared to
  # it (PostgreSQL refuses bigint = varchar outright), and on MySQL it appends a
  # COLLATE so the comparison is not case-folded. Every other test here uses
  # bigint-keyed User, so that cast was written for UUID keys and never run
  # against one. bin/db drives this on all three adapters.
  test "members offers UUID-keyed candidates, and excludes the one already holding the role" do
    original = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "UuidUser"

    holder = UuidUser.create!(id: "7f00aaaa-1111-4111-8111-aaaaaaaaaaaa", name: "Alice")
    free   = UuidUser.create!(id: "7f00bbbb-2222-4222-8222-bbbbbbbbbbbb", name: "Bob")
    CurrentScope::RoleAssignment.create!(subject: holder, role: @role)

    get current_scope.members_role_url(@role), headers: as(@owner)

    assert_response :success
    assert_select "td", text: "Alice", count: 1
    assert_select "select[name='subject_gids[]'] option", text: "Bob"
    assert_select "select[name='subject_gids[]'] option", { text: "Alice", count: 0 },
                  "Alice already holds the role org-wide — both ids start \"7f00\", so a " \
                  "cast that truncated them would exclude Bob instead of Alice (#151)"
    assert_equal 2, UuidUser.count, "precondition: both candidates are distinct records"
    assert_not_equal free.id, holder.id
  ensure
    CurrentScope.config.subject_class = original
  end

  test "members survives a stale/renamed polymorphic resource type without 500ing" do
    folder = Folder.create!(name: "Space")
    bob = User.create!(name: "Bob")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: bob, resource: folder, role: @role)
    sra.update_column(:resource_type, "RemovedModel") # class no longer constantizes

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_match(/RemovedModel ##{folder.id}/, response.body)
    assert_match(/unavailable — inert/, response.body)
    assert_select "#scoped_holder_#{sra.id}.cs-scoped-holder.cs-row--inert"
    assert_match(/Remove inert/, response.body)
    assert_select "#scoped_revoke_#{sra.id}"
  end

  # #90 — deleted resource leaves an inert scoped grant that must not look live.
  test "members labels a deleted resource as inert and can revoke it" do
    folder = Folder.create!(name: "Doomed")
    bob = User.create!(name: "Bob")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: bob, resource: folder, role: @role)
    folder.destroy!

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_match(/unavailable — inert/, response.body)
    assert_select ".cs-inert-badge", text: "inert"
    assert_select "#scoped_revoke_#{sra.id}"

    assert_difference -> { CurrentScope::ScopedRoleAssignment.count }, -1 do
      delete current_scope.scoped_role_assignment_url(sra), headers: as(@owner)
    end
  end

  test "adding org-wide members from the role side sets the role and returns to members" do
    carol = User.create!(name: "Carol")
    post current_scope.role_assignments_url,
         headers: as(@owner).merge("HTTP_REFERER" => current_scope.members_role_url(@role)),
         params: { role_id: @role.id, subject_gids: [ carol.to_gid.to_s ] }
    assert_redirected_to current_scope.members_role_path(@role)
    assert_equal @role, CurrentScope::RoleAssignment.find_by(subject: carol)&.role
  end

  test "an orphaned org-wide assignment (deleted subject) can be removed by id" do
    ghost = User.create!(name: "Ghost")
    assignment = CurrentScope::RoleAssignment.create!(subject: ghost, role: @role)
    ghost.delete # hard-delete, no cascade → the assignment is now orphaned

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "form[action=?]", current_scope.role_assignment_path(assignment)

    assert_difference -> { CurrentScope::RoleAssignment.count }, -1 do
      delete current_scope.role_assignment_url(assignment), headers: as(@owner)
    end
    assert_not CurrentScope::RoleAssignment.exists?(assignment.id)
  end

  test "removing an org-wide holder clears their role" do
    dave = User.create!(name: "Dave")
    CurrentScope::RoleAssignment.create!(subject: dave, role: @role)
    post current_scope.role_assignments_url, headers: as(@owner),
         params: { subject_gid: dave.to_gid.to_s, role_id: "" }
    assert_nil CurrentScope::RoleAssignment.find_by(subject: dave)
  end
end
