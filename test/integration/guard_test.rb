require "test_helper"

class GuardTest < ActionDispatch::IntegrationTest
  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  def assign(user, role)
    CurrentScope::RoleAssignment.create!(subject: user, role: role)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  test "anonymous requests are forbidden (fail closed)" do
    get reports_url
    assert_response :forbidden
  end

  test "a signed-in user without the permission is forbidden" do
    assign(@alice, role("Member", "reports#show"))
    get reports_url, headers: sign_in(@alice)
    assert_response :forbidden
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]
  end

  test "granting the controller action opens the gate" do
    assign(@alice, role("Member", "reports#index"))
    get reports_url, headers: sign_in(@alice)
    assert_response :success
    assert_equal "Q3", response.body
  end

  test "full_access passes every gate" do
    assign(@alice, role("Owner", full_access: true))
    get reports_url, headers: sign_in(@alice)
    assert_response :success
    post approve_report_url(@report), headers: sign_in(@alice)
    assert_response :success
  end

  test "SoD veto blocks self-approval at the controller gate, even for full_access" do
    assign(@bob, role("Owner", full_access: true))
    post approve_report_url(@report), headers: sign_in(@bob)
    assert_response :forbidden
    assert_equal "sod_veto", response.headers["X-Current-Scope-Reason"]
  end

  test "a ?id= query string cannot smuggle a scoped record into a collection action" do
    assign(@alice, role("Member"))   # no org-wide permissions
    viewer = role("Viewer", "reports#index", "reports#show")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)

    get reports_url(id: @report.id), headers: sign_in(@alice)
    assert_response :forbidden
  end

  test "gating an excluded controller raises a configuration error" do
    assign(@alice, role("Owner", full_access: true))

    assert_raises(CurrentScope::ConfigurationError) do
      post webhooks_url, headers: sign_in(@alice)
    end
  end

  test "a missing user_method raises instead of silently denying" do
    assert_raises(CurrentScope::ConfigurationError) do
      get bare_url
    end
  end

  test "a scoped role opens member actions on that record only" do
    assign(@alice, role("Member"))
    viewer = role("Viewer", "reports#show")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)
    other = Report.create!(title: "Q4", requested_by: @bob)

    get report_url(@report), headers: sign_in(@alice)
    assert_response :success

    get report_url(other), headers: sign_in(@alice)
    assert_response :forbidden
  end
end
