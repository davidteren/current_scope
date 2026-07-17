require "test_helper"

# #65 end-to-end: for actions in config.collection_read_actions the record-less
# gate derives its answer from the scoped list, THROUGH the Guard/request
# stack. The resolver-unit truth lives in test/collection_scope_gate_test.rb;
# this file proves the wiring — the hooks thread the type, the reason rides the
# header, report mode stops surveying what is now a genuine allow, and the
# opt-out restores the 0.2 request behavior.
class CollectionReadGateTest < ActionDispatch::IntegrationTest
  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @mine = Report.create!(title: "Mine", requested_by: @bob)
    @other = Report.create!(title: "Other", requested_by: @bob)
    @owner = role("Owner", full_access: true)
    scope_grant(@alice, @owner, @mine)

    @original_reads = CurrentScope.config.collection_read_actions
    @original_enforcement = CurrentScope.config.enforcement
  end

  teardown do
    CurrentScope.config.collection_read_actions = @original_reads
    CurrentScope.config.enforcement = @original_enforcement
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def scope_grant(user, role, record)
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: record)
  end

  test "default posture: the scoped full_access owner opens the index and sees exactly her record" do
    get reports_url, headers: sign_in(@alice)

    assert_response :success
    assert_equal "Mine", response.body, "scope_for narrows the same query the gate derived from — her record, not Bob's"
  end

  test "default posture: the same shape of grant cannot reach a record-less write" do
    # ReportsController routes no collection write, so the write-denial leg
    # runs on ProjectsController — it routes #create and declares its model,
    # the same record-less shape on a buildable surface.
    project = Project.create!(name: "Apollo")
    scope_grant(@alice, role("ProjectOwner", full_access: true), project)

    get projects_url, headers: sign_in(@alice)
    assert_response :success
    assert_equal "Apollo", response.body

    post projects_url, headers: sign_in(@alice)
    assert_response :forbidden, "create has no list side — a scoped full_access grant must not open it"
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]
  end

  test "opt-out: an empty collection_read_actions restores the 0.2 request behavior" do
    CurrentScope.config.collection_read_actions = []

    get reports_url, headers: sign_in(@alice)

    assert_response :forbidden
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]
  end

  test "report mode no longer surveys the now-genuine allow" do
    CurrentScope.config.enforcement = :report

    assert_no_difference -> { CurrentScope::Event.count } do
      get reports_url, headers: sign_in(@alice)
    end
    assert_response :success
    assert_nil response.headers["X-Current-Scope-Reason"], "a genuine allow carries no reason"
  end

  # Scope Boundaries safety check for the orphan-grant follow-up: under #65 a
  # grant on a destroyed record opens nothing, but its row still renders in
  # the console. The page must degrade, not 500 — reaping/labeling orphans is
  # the follow-up issue's scope, rendering them safely is this PR's floor.
  test "the console renders a scoped grant whose resource is gone without a 500" do
    admin = User.create!(name: "Admin")
    CurrentScope::RoleAssignment.create!(subject: admin, role: role("Root", full_access: true))
    @mine.destroy!

    get current_scope.members_role_url(@owner), headers: sign_in(admin)

    assert_response :success
  end
end
