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
end
