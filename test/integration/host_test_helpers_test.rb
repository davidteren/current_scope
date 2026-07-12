require "test_helper"
require "current_scope/test_helpers"

# A3: host apps need to place a subject in a role and assert allow/deny through
# the REAL gate in a few lines. with_current_user only sets Current.user
# in-process (Context's before_action overwrites it on a real request), so it
# can't test controllers behind the gate. grant_role! / grant_scoped_role! seed
# real assignment rows that survive the request cycle.
class HostTestHelpersTest < ActionDispatch::IntegrationTest
  include CurrentScope::TestHelpers

  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  def role(name, *keys)
    r = CurrentScope::Role.create!(name: name)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  test "grant_role! seeds an org-wide grant the real gate honors" do
    grant_role!(@alice, role: role("Member", "reports#index"))

    get reports_url, headers: sign_in(@alice)
    assert_response :success

    # destroy is not granted → the real gate denies
    delete report_url(@report), headers: sign_in(@alice)
    assert_response :forbidden
  end

  test "grant_scoped_role! opens exactly one record through the gate" do
    grant_role!(@alice, role: role("Member")) # no org-wide show
    grant_scoped_role!(@alice, role: role("Viewer", "reports#show"), record: @report)
    other = Report.create!(title: "Q4", requested_by: @bob)

    get report_url(@report), headers: sign_in(@alice)
    assert_response :success

    get report_url(other), headers: sign_in(@alice)
    assert_response :forbidden
  end

  test "the persisting helpers return the created assignment" do
    assignment = grant_role!(@alice, role: role("Member", "reports#index"))
    assert_kind_of CurrentScope::RoleAssignment, assignment
    assert assignment.persisted?
  end
end
