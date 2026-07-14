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
