require "test_helper"

class GuardTest < ActionDispatch::IntegrationTest
  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
    # SoD is opt-in (empty by default); this suite asserts the gate veto, so enable it.
    @original_sod_actions = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
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

  # current_scope_record keys off request.path_parameters, never params, so a
  # query-string ?id= is inert on a collection route. Asserted in BOTH
  # directions — the ?id= must change nothing, neither opening a gate that is
  # shut nor shutting one that is open. (Before the record-less scoped gate
  # landed, the "shut" half passed for the wrong reason: a scoped-only subject
  # was denied every collection action regardless of the query string, so it
  # proved the bug, not the path_parameters rule.)
  test "a ?id= query string cannot smuggle a scoped record into a collection action" do
    assign(@alice, role("Member"))   # no org-wide permissions
    viewer = role("Viewer", "reports#show") # scoped, but does NOT tick reports#index
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)

    # The grant is on @report and ticks show — naming that very record in the
    # query string must not upgrade it into index access.
    get reports_url(id: @report.id), headers: sign_in(@alice)
    assert_response :forbidden
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]

    get reports_url, headers: sign_in(@alice)
    assert_response :forbidden, "the ?id= must make no difference"
  end

  test "a ?id= query string cannot shut a collection gate the subject legitimately holds" do
    viewer = role("Viewer", "reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)

    # The converse of the smuggle test: the scoped grant opens the record-less
    # index gate, and the query string is inert here too.
    get reports_url(id: @report.id), headers: sign_in(@alice)
    assert_response :success

    get reports_url, headers: sign_in(@alice)
    assert_response :success
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
