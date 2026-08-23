require "test_helper"

# The role-side members view: who holds a role (org-wide + scoped), and adding
# org-wide members from the role rather than the subject.
class RoleMembersTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    @owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    @role = CurrentScope::Role.create!(name: "Editor")
    @original_polymorphic_names = CurrentScope.config.polymorphic_class_names
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  # Latches a real ConfigurationError on the registry: the config names a token
  # that User does not store, so the rebuild refuses and every later lookup
  # re-raises. Undone in teardown, because the latch is a process-wide ivar.
  def poison_registry!
    CurrentScope.config.polymorphic_class_names = { "old_token" => "User" }
    assert_raises(CurrentScope::ConfigurationError) { CurrentScope.rebuild_polymorphic_registry! }
  end

  teardown do
    # Restore rather than blank: a future test may set these legitimately, and
    # the latch is a process-wide ivar that outlives this test either way.
    CurrentScope.config.polymorphic_class_names = @original_polymorphic_names
    CurrentScope.rebuild_polymorphic_registry!
  end

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

  test "members does not re-offer a holder stored under a custom subject token" do
    holder = User.create!(name: "TokenHolder")
    free = User.create!(name: "TokenFree")
    now = Time.current
    CurrentScope::RoleAssignment.insert!({
      role_id: @role.id,
      subject_type: "token_people",
      subject_id: holder.id.to_s,
      created_at: now,
      updated_at: now
    })

    token_user = Class.new(User) do
      def self.name = "TokenPeopleUser"
      def self.polymorphic_name = "token_people"
    end
    Object.send(:const_set, "TokenPeopleUser", token_user)
    CurrentScope.rebuild_polymorphic_registry!

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "td", text: "TokenHolder"
    assert_select "select[name='subject_gids[]'] option", text: "TokenFree"
    assert_select "select[name='subject_gids[]'] option", { text: "TokenHolder", count: 0 }
  ensure
    Object.send(:remove_const, :TokenPeopleUser) if defined?(TokenPeopleUser)
    CurrentScope.rebuild_polymorphic_registry!
  end

  # The held-set is filtered by reverse-resolving TOKEN, not by a plucked
  # subject_id list. A holder stored under a different base class's token
  # (token_docs -> TokenDocument) must not exclude a real subject whose id merely
  # collides with that holder's subject_id — the base_class guard drops the token.
  test "a holder stored under a different base class's token does not exclude a colliding candidate" do
    free = User.create!(name: "FreeUser")
    now = Time.current
    # Same numeric id as a real User, but stored under a TokenDocument token.
    CurrentScope::RoleAssignment.insert!({
      role_id: @role.id,
      subject_type: "token_docs",
      subject_id: free.id.to_s,
      created_at: now,
      updated_at: now
    })

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    # free does NOT hold @role as a User — the token_docs holder is a different
    # base class — so free is still offered to add.
    assert_select "select[name='subject_gids[]'] option", text: "FreeUser"
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

  # #166 — a poisoned registry must degrade the console, not 500 it. This is the
  # page an operator opens to find and fix broken grants, so it has to render.
  test "members survives a poisoned polymorphic registry without 500ing" do
    folder = Folder.create!(name: "Space")
    bob = User.create!(name: "Bob")
    # The grant is created BEFORE the poison: create! validates through the
    # registry and would refuse afterwards, which is the write path staying
    # fail-closed and is asserted separately below.
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: bob, resource: folder, role: @role)
    poison_registry!

    get current_scope.members_role_url(@role), headers: as(@owner)

    assert_response :success
    assert_select "#cs-registry-error"
    assert_match(/Registry misconfigured/, response.body)
    assert_select "#scoped_holder_#{sra.id}.cs-row--inert"
    assert_match(/unavailable — inert/, response.body)
  end

  # Reads degrade; writes stay closed. A grant must not be saved under a registry
  # that cannot say which class a token names, and the refusal must name the real
  # cause rather than claim the token is unmapped.
  test "a poisoned registry still refuses to write a grant, naming the cause" do
    bob = User.create!(name: "Bob")
    poison_registry!

    error = assert_raises NameError do
      CurrentScope::RoleAssignment.create!(subject: bob, role: @role)
    end
    assert_match(/old_token/, error.message, "the refusal must name the registry problem")
    assert_not CurrentScope::RoleAssignment.exists?(subject_id: bob.id.to_s)
  end

  # #166 — the 500 was accidentally guarding the delete. Now that the page
  # renders, the last-holder rule must refuse rather than read every holder as
  # inert and conclude nobody holds full access.
  test "a poisoned registry refuses to delete a full-access role" do
    poison_registry!

    delete current_scope.role_url(@owner_role), headers: as(@owner)

    assert_response :redirect
    assert CurrentScope::Role.exists?(@owner_role.id),
           "a registry that cannot resolve holders must not authorise the delete"
    assert_match(/registry is misconfigured/, flash[:alert].to_s,
                 "the operator must be told the real reason, not blamed on a last holder")
  end

  # #166 — the UNLATCHED collision. registry_blind? cannot see this one before the
  # scan starts, because nothing latches and no labeling lookup has run yet in
  # this request. Found by qodo and Devin on PR #181 against the first fix.
  test "an unlatched registry collision refuses to delete a full-access role" do
    CurrentScope.rebuild_polymorphic_registry!
    # A registered owner that disagrees with what Rails constantizes the token to.
    CurrentScope.polymorphic_registry.dup.tap do |map|
      map["User"] = Folder
      CurrentScope::PolymorphicRegistry.instance_variable_set(:@polymorphic_registry, map.freeze)
    end
    assert_nil CurrentScope::PolymorphicRegistry.error, "this path must not latch"

    delete current_scope.role_url(@owner_role), headers: as(@owner)

    # Refused CLEANLY, not by 500ing: a crash also leaves the role in place, so
    # the existence check alone cannot tell the two apart.
    assert_response :redirect
    assert CurrentScope::Role.exists?(@owner_role.id),
           "a collision the latch cannot see must still refuse the delete"
  ensure
    CurrentScope.rebuild_polymorphic_registry!
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
    assert_select "#org_holder_#{assignment.id}"
    assert_select "#org_holder_#{assignment.id} .cs-inert-badge", count: 0
    assert_select "#org_holder_#{assignment.id}", text: /subject deleted/

    assert_difference -> { CurrentScope::RoleAssignment.count }, -1 do
      delete current_scope.role_assignment_url(assignment), headers: as(@owner)
    end
    assert_not CurrentScope::RoleAssignment.exists?(assignment.id)
  end

  test "an unmapped-token org holder is badged inert, not deleted" do
    now = Time.current
    CurrentScope::RoleAssignment.insert!({
      role_id: @role.id,
      subject_type: "token_people_unmapped_164",
      subject_id: "5",
      created_at: now,
      updated_at: now
    })
    assignment = CurrentScope::RoleAssignment.find_by!(subject_type: "token_people_unmapped_164")

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "#org_holder_#{assignment.id}.cs-row--inert"
    assert_select "#org_holder_#{assignment.id} .cs-inert-badge", text: "inert"
    assert_select "#org_remove_#{assignment.id}", text: "Remove inert"
    assert_select "#org_holder_#{assignment.id}", text: /subject deleted/, count: 0

    assert_difference -> { CurrentScope::RoleAssignment.count }, -1 do
      delete current_scope.role_assignment_url(assignment), headers: as(@owner)
    end
  end

  test "a healthy org holder has a stable row id and no inert badge" do
    alice = User.create!(name: "Alice")
    assignment = CurrentScope::RoleAssignment.create!(subject: alice, role: @role)

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "#org_holder_#{assignment.id}.cs-org-holder"
    assert_select "#org_holder_#{assignment.id}.cs-row--inert", count: 0
    assert_select "#org_holder_#{assignment.id} .cs-inert-badge", count: 0
    assert_select "td", text: "Alice"
  end

  test "add copy does not claim full coverage when there are zero subjects" do
    original = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "UuidUser"
    UuidUser.delete_all

    get current_scope.members_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "#org_add_empty"
    assert_no_match(/Every subject already holds this role org-wide/, response.body)
  ensure
    CurrentScope.config.subject_class = original
  end

  test "removing an org-wide holder clears their role" do
    dave = User.create!(name: "Dave")
    CurrentScope::RoleAssignment.create!(subject: dave, role: @role)
    post current_scope.role_assignments_url, headers: as(@owner),
         params: { subject_gid: dave.to_gid.to_s, role_id: "" }
    assert_nil CurrentScope::RoleAssignment.find_by(subject: dave)
  end
end
