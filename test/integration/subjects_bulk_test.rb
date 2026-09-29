require "test_helper"

# Subjects page: config-driven identity labels, filter/multi-select scaffolding,
# and bulk scoped-role granting.
class SubjectsBulkTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @role = CurrentScope::Role.create!(name: "Reviewer")
    @original_label = CurrentScope.config.subject_label
  end

  teardown { CurrentScope.config.subject_label = @original_label }

  def as(user) = { "X-User-Id" => user.id.to_s }

  def with_management_authorizer(authorizer)
    prior = CurrentScope.config.management_authorizer
    CurrentScope.config.management_authorizer = authorizer
    yield
  ensure
    CurrentScope.config.management_authorizer = prior
  end

  test "config.subject_label controls how a subject is identified" do
    alice = User.create!(name: "Alice Cooper")
    CurrentScope.config.subject_label = ->(u) { "user-#{u.name.parameterize}" }

    get current_scope.subjects_url, headers: as(@owner)
    assert_response :success
    assert_match "user-alice-cooper", response.body
  end

  test "the subjects page ships filter + multi-select scaffolding" do
    User.create!(name: "Someone")
    get current_scope.subjects_url, headers: as(@owner)
    assert_select "[data-cs-filter]"
    assert_select "[data-cs-select-all]"
    assert_select "tbody tr[data-cs-row] [data-cs-select]"
    assert_select "[data-cs-bulk] [data-cs-bulk-scoped]"
  end

  # #90 — orphaned scoped grants must not look like live access.
  test "subjects page marks a scoped grant on a deleted record as inert" do
    alice = User.create!(name: "Alice")
    folder = Folder.create!(name: "Gone")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: folder, role: @role)
    folder.destroy!

    get current_scope.subjects_url, headers: as(@owner)
    assert_response :success
    assert_select "#scoped_chip_#{sra.id}.cs-chip--inert.cs-scoped-chip"
    assert_match(/unavailable — inert/, response.body)
    assert_select ".cs-inert-badge", text: "inert"
  end

  test "subjects page survives a stale resource_type without 500ing" do
    alice = User.create!(name: "Alice")
    folder = Folder.create!(name: "X")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: folder, role: @role)
    sra.update_column(:resource_type, "RemovedModel")

    get current_scope.subjects_url, headers: as(@owner)
    assert_response :success
    assert_match(/RemovedModel ##{folder.id}/, response.body)
    assert_select "#scoped_chip_#{sra.id}.cs-chip--inert"
  end

  test "the picker renders bulk mode for multiple subject_gids" do
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")
    get current_scope.new_scoped_role_assignment_url(subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]),
        headers: as(@owner)
    assert_response :success
    assert_select "input[type=hidden][name='subject_gids[]']", count: 2
  end

  test "a bulk grant creates the scoped role for every selected subject" do
    folder = Folder.create!(name: "Team space")
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")

    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      role_id: @role.id, resource_gid: folder.to_gid.to_s,
      subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]
    }
    assert_redirected_to current_scope.subjects_path

    assert_equal 1, CurrentScope::ScopedRoleAssignment.where(subject: alice, resource: folder, role: @role).count
    assert_equal 1, CurrentScope::ScopedRoleAssignment.where(subject: bob, resource: folder, role: @role).count
  end

  test "a bulk scoped grant rejects subject_gids that aren't the configured subject class" do
    folder = Folder.create!(name: "Team space")
    not_a_subject = Folder.create!(name: "Target")
    # A crafted GID for a non-subject model must never create an assignment row.
    assert_no_difference -> { CurrentScope::ScopedRoleAssignment.count } do
      post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
        role_id: @role.id, resource_gid: folder.to_gid.to_s,
        subject_gids: [ not_a_subject.to_gid.to_s ]
      }
    end
    assert_equal "No subjects selected.", flash[:alert]
  end

  test "a bulk org-wide assignment rejects non-subject GIDs instead of reporting a silent success" do
    not_a_subject = Folder.create!(name: "Not a subject")
    assert_no_difference -> { CurrentScope::RoleAssignment.count } do
      post current_scope.role_assignments_url, headers: as(@owner), params: {
        role_id: @role.id, subject_gids: [ not_a_subject.to_gid.to_s ]
      }
    end
    assert_equal "No subjects selected.", flash[:alert]
  end

  test "duplicate subject_gids in a bulk org assignment are counted and audited once" do
    alice = User.create!(name: "Alice")
    assert_difference -> { CurrentScope::RoleAssignment.count }, 1 do
      post current_scope.role_assignments_url, headers: as(@owner), params: {
        role_id: @role.id, subject_gids: [ alice.to_gid.to_s, alice.to_gid.to_s ]
      }
    end
    assert_equal "Org-wide role set.", flash[:notice] # singular ⇒ counted once, not twice
  end

  test "subject rows carry filter text including their roles (role-name filtering works)" do
    alice = User.create!(name: "Alice")
    CurrentScope::RoleAssignment.create!(subject: alice, role: @role) # @role => "Reviewer"
    get current_scope.subjects_url, headers: as(@owner)
    assert_select "tr[data-cs-row][data-cs-filter-text*=?]", "Reviewer"
  end

  test "a bulk set counts only the subjects whose role actually changed" do
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")
    CurrentScope::RoleAssignment.create!(subject: alice, role: @role) # already holds @role

    post current_scope.role_assignments_url, headers: as(@owner), params: {
      role_id: @role.id, subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]
    }
    # only bob changed ⇒ singular notice, not "for 2 subjects"
    assert_equal "Org-wide role set.", flash[:notice]
  end

  test "a bulk clear that changes nothing reports no changes, not a false success" do
    alice = User.create!(name: "Alice") # holds no org-wide role
    post current_scope.role_assignments_url, headers: as(@owner), params: {
      role_id: "", subject_gids: [ alice.to_gid.to_s ]
    }
    assert_equal "No org-wide role changes.", flash[:notice]
  end

  test "the bulk bar offers an org-wide role form" do
    User.create!(name: "Someone")
    get current_scope.subjects_url, headers: as(@owner)
    assert_select "[data-cs-bulk] [data-cs-bulk-org]"
  end

  test "a bulk org-wide assignment sets the role for every selected subject" do
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")

    post current_scope.role_assignments_url, headers: as(@owner), params: {
      role_id: @role.id, subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]
    }
    assert_redirected_to current_scope.subjects_path

    assert_equal @role, CurrentScope::RoleAssignment.find_by(subject: alice)&.role
    assert_equal @role, CurrentScope::RoleAssignment.find_by(subject: bob)&.role
  end

  test "a bulk org-wide clear (blank role) removes the role for every selected subject" do
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")
    CurrentScope::RoleAssignment.create!(subject: alice, role: @role)
    CurrentScope::RoleAssignment.create!(subject: bob, role: @role)

    post current_scope.role_assignments_url, headers: as(@owner), params: {
      role_id: "", subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]
    }
    assert_nil CurrentScope::RoleAssignment.find_by(subject: alice)
    assert_nil CurrentScope::RoleAssignment.find_by(subject: bob)
  end

  test "a bulk grant skips subjects that already have it and reports the rest" do
    folder = Folder.create!(name: "Team space")
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")
    CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: folder, role: @role)

    assert_difference -> { CurrentScope::ScopedRoleAssignment.count }, 1 do
      post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
        role_id: @role.id, resource_gid: folder.to_gid.to_s,
        subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]
      }
    end
    assert_equal 1, CurrentScope::ScopedRoleAssignment.where(subject: bob).count
  end

  test "a full-access subject keeps an enabled scoped revoke and the unknown submits" do
    alice = User.create!(name: "Alice")
    folder = Folder.create!(name: "Space")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: folder, role: @role)

    get current_scope.subjects_url, headers: as(@owner)

    assert_response :success
    button = css_select("#scoped_chip_revoke_#{sra.id}").first
    assert_nil button["disabled"]
    assert_match @role.name, button["aria-label"]
    assert_nil button["aria-describedby"]
    assert_select "#scoped_chip_revoke_#{sra.id}_limit", count: 0
    assert_select "input[type=submit][value='Set for selected']:not([disabled])"
    assert_select "input[type=submit][value='Set']:not([disabled])"
    assert_select "a[data-cs-bulk-scoped]"
    assert_select "a.cs-add-scoped"
    assert_select "select[name=role_id] option[disabled]", count: 0
  end

  test "a denied scoped revoke is disabled and described, and unknown submits stay open" do
    alice = User.create!(name: "Alice")
    folder = Folder.create!(name: "Space")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: folder, role: @role)
    delegate = User.create!(name: "Delegate")
    actions = []
    authorizer = lambda do |subject, action:, **|
      actions << action
      subject == delegate && action == :access
    end

    with_management_authorizer(authorizer) do
      get current_scope.subjects_url, headers: as(delegate)
    end

    assert_response :success
    button = css_select("#scoped_chip_revoke_#{sra.id}").first
    assert button["disabled"]
    assert_equal "scoped_chip_revoke_#{sra.id}_limit", button["aria-describedby"]
    assert_match @role.name, button["aria-label"]
    assert_select "#scoped_chip_revoke_#{sra.id}_limit",
      text: "Your administration permissions do not allow this removal."
    assert_select "input[type=submit][value='Set for selected']:not([disabled])"
    assert_select "input[type=submit][value='Set']:not([disabled])"
    assert_select "a[data-cs-bulk-scoped]"
    assert_select "a.cs-add-scoped"
    assert_select "select[name=role_id] option[disabled]", count: 0
    assert_not_includes actions, :assign_role
    assert_not_includes actions, :assign_scoped_role
  end

  test "a scoped revoke asks once and uses the recipient, not the resource" do
    alice = User.create!(name: "Alice")
    CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: Folder.create!(name: "One"), role: @role)
    CurrentScope::ScopedRoleAssignment.create!(subject: alice, resource: Folder.create!(name: "Two"), role: @role)
    calls = []
    authorizer = lambda do |subject, action:, role: nil, target: nil|
      calls << [ action, role&.id, target&.class&.name, target&.id ] if action == :revoke_scoped_role
      subject == @owner
    end

    with_management_authorizer(authorizer) do
      get current_scope.subjects_url, headers: as(@owner)
    end

    assert_response :success
    assert_equal [ [ :revoke_scoped_role, @role.id, "User", alice.id ] ], calls
  end

  test "a mixed org-role batch changes the allowed subject and names the skip" do
    delegate = User.create!(name: "Delegate")
    allowed = User.create!(name: "Allowed Person")
    skipped = User.create!(name: "Skipped Person")
    editor = CurrentScope::Role.create!(name: "Editor")
    authorizer = lambda do |actor, action:, target: nil, **|
      next false unless actor == delegate
      return true if action == :access
      return true if target == allowed

      "yes"
    end

    with_management_authorizer(authorizer) do
      assert_difference -> { CurrentScope::Event.where(event: "org_role.assigned").count }, 1 do
        post current_scope.role_assignments_url, headers: as(delegate), params: {
          role_id: editor.id,
          subject_gids: [ allowed.to_gid.to_s, skipped.to_gid.to_s ]
        }
      end
    end

    assert_redirected_to current_scope.subjects_path
    assert_equal "Org-wide role set. Skipped Skipped Person.", flash[:notice]
    assert_equal editor, CurrentScope::RoleAssignment.find_by(subject: allowed)&.role
    assert_nil CurrentScope::RoleAssignment.find_by(subject: skipped)
    targets = CurrentScope::Event.where(event: "org_role.assigned").pluck(:target)
    assert targets.any? { |target| target.include?(allowed.to_gid.to_s) }
    assert targets.none? { |target| target.include?(skipped.to_gid.to_s) }
  end

  test "a long skipped list still redirects after the allowed change" do
    delegate = User.create!(name: "Delegate")
    allowed = User.create!(name: "Allowed Person")
    skipped = Array.new(100) { |index| User.create!(name: "Skipped #{index} #{'x' * 60}") }
    editor = CurrentScope::Role.create!(name: "Editor")
    authorizer = lambda do |actor, action:, target: nil, **|
      next false unless actor == delegate
      return true if action == :access
      return true if target == allowed

      "yes"
    end

    with_management_authorizer(authorizer) do
      post current_scope.role_assignments_url, headers: as(delegate), params: {
        role_id: editor.id,
        subject_gids: [ allowed.to_gid.to_s, *skipped.map { |user| user.to_gid.to_s } ]
      }
    end

    assert_redirected_to current_scope.subjects_path
    notice = flash[:notice].to_s
    assert_operator notice.bytesize, :<, 2_000
    assert_match(/And \d+ more\./, notice)
    assert_equal editor, CurrentScope::RoleAssignment.find_by(subject: allowed)&.role
    assert_nil CurrentScope::RoleAssignment.find_by(subject: skipped.first)
  end

  test "a role change still checks revoke before it applies the allowed subject" do
    delegate = User.create!(name: "Delegate")
    kept = User.create!(name: "Kept Person")
    moved = User.create!(name: "Moved Person")
    CurrentScope::RoleAssignment.create!(subject: kept, role: @role)
    editor = CurrentScope::Role.create!(name: "Editor")
    authorizer = lambda do |actor, action:, target: nil, **|
      next false unless actor == delegate
      return true if action == :access
      return false if action == :revoke_role && target == kept

      true
    end

    with_management_authorizer(authorizer) do
      post current_scope.role_assignments_url, headers: as(delegate), params: {
        role_id: editor.id,
        subject_gids: [ kept.to_gid.to_s, moved.to_gid.to_s ]
      }
    end

    assert_redirected_to current_scope.subjects_path
    assert_equal "Org-wide role set. Skipped Kept Person.", flash[:notice]
    assert_equal @role, CurrentScope::RoleAssignment.find_by!(subject: kept).role
    assert_equal editor, CurrentScope::RoleAssignment.find_by!(subject: moved).role
    assert_equal 0, CurrentScope::Event.where(event: "org_role.changed").count
  end

  test "a fully denied org-role batch changes nothing and writes no event" do
    delegate = User.create!(name: "Delegate")
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")
    authorizer = ->(actor, action:, **) { actor == delegate && action == :access }

    with_management_authorizer(authorizer) do
      assert_no_difference -> { CurrentScope::Event.count } do
        post current_scope.role_assignments_url, headers: as(delegate), params: {
          role_id: @role.id,
          subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]
        }
      end
    end

    assert_response :forbidden
    assert_equal "management_denied", response.headers["X-Current-Scope-Reason"]
    assert_nil CurrentScope::RoleAssignment.find_by(subject: alice)
    assert_nil CurrentScope::RoleAssignment.find_by(subject: bob)
  end

  test "a mixed batch refuses when the allowed recipient is the last full-access holder" do
    delegate = User.create!(name: "Delegate")
    colleague = User.create!(name: "Colleague")
    CurrentScope::RoleAssignment.create!(subject: colleague, role: @role)
    authorizer = lambda do |actor, action:, target: nil, **|
      actor == delegate && (action == :access || target == @owner)
    end

    with_management_authorizer(authorizer) do
      assert_no_difference -> { CurrentScope::Event.count } do
        post current_scope.role_assignments_url, headers: as(delegate), params: {
          role_id: @role.id,
          subject_gids: [ @owner.to_gid.to_s, colleague.to_gid.to_s ]
        }
      end
    end

    assert_response :redirect
    assert_match(/last full access/i, flash[:alert].to_s)
    assert CurrentScope::RoleAssignment.find_by!(subject: @owner).role.full_access?
    assert_equal @role, CurrentScope::RoleAssignment.find_by!(subject: colleague).role
  end

  test "a denied last holder does not block a change the subject may make" do
    delegate = User.create!(name: "Delegate")
    colleague = User.create!(name: "Colleague")
    editor = CurrentScope::Role.create!(name: "Editor")
    authorizer = lambda do |actor, action:, target: nil, **|
      actor == delegate && (action == :access || target == colleague)
    end

    with_management_authorizer(authorizer) do
      assert_difference -> { CurrentScope::Event.where(event: "org_role.assigned").count }, 1 do
        post current_scope.role_assignments_url, headers: as(delegate), params: {
          role_id: editor.id,
          subject_gids: [ @owner.to_gid.to_s, colleague.to_gid.to_s ]
        }
      end
    end

    assert_redirected_to current_scope.subjects_path
    assert_equal "Org-wide role set. Skipped Owner.", flash[:notice]
    assert CurrentScope::RoleAssignment.find_by!(subject: @owner).role.full_access?
    assert_equal editor, CurrentScope::RoleAssignment.find_by!(subject: colleague).role
  end

  test "a non-authorization error is not treated as a skipped recipient" do
    delegate = User.create!(name: "Delegate")
    alice = User.create!(name: "Alice")
    bob = User.create!(name: "Bob")
    authorizer = lambda do |actor, action:, target: nil, **|
      raise RuntimeError, "not an authorization result" if target == alice

      actor == delegate && (action == :access || target == bob)
    end

    with_management_authorizer(authorizer) do
      assert_raises(RuntimeError) do
        post current_scope.role_assignments_url, headers: as(delegate), params: {
          role_id: @role.id,
          subject_gids: [ alice.to_gid.to_s, bob.to_gid.to_s ]
        }
      end
    end

    assert_nil CurrentScope::RoleAssignment.find_by(subject: alice)
    assert_nil CurrentScope::RoleAssignment.find_by(subject: bob)
  end
end
