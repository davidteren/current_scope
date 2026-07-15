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

  # A HOST denial stays a bodyless head :forbidden. The engine renders an
  # explanation page for its own front door (#23), and that must not leak into
  # the shared denial path — a host app would suddenly emit an engine-styled
  # body into its own response contract, with no layout or view guarantee.
  test "a host denial has no body — the engine's explanation page is engine-only" do
    assign(@alice, role("Member", "reports#show"))

    get reports_url, headers: sign_in(@alice)
    assert_response :forbidden
    assert_empty response.body, "the host's denial contract must not change"
  end

  test "a host SoD veto also stays bodyless" do
    assign(@bob, role("Owner", full_access: true))

    post approve_report_url(@report), headers: sign_in(@bob)
    assert_response :forbidden
    assert_equal "sod_veto", response.headers["X-Current-Scope-Reason"]
    assert_empty response.body
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

  # This is the test that actually holds the path_parameters rule up, so it is
  # built to FAIL if the hook ever reads params: the ?id= names a record Alice
  # has NO grant on, which is the only shape that still discriminates now that
  # the record-less branch allows on any scoped grant ticking the key.
  #
  #   correct hook  → path_parameters has no :id on the collection route → nil
  #                 → record-less branch → Alice's reports#index grant → 200
  #   mutated hook  → params[:id] smuggles `other` in → scoped_grant? finds no
  #                 → grant on `other` → 403 → RED
  #
  # (Verified by mutation: flipping the hook to `report if params[:id]` turns
  # this red and leaves the rest of the file green.)
  test "a ?id= query string is inert on a collection route (hook reads path_parameters)" do
    other = Report.create!(title: "Q4", requested_by: @bob) # Alice holds NO grant on this
    viewer = role("Viewer", "reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)

    get reports_url(id: other.id), headers: sign_in(@alice)
    assert_response :success, "the hook must ignore params[:id] — reading it would smuggle " \
      "an ungranted record into the gate and wrongly deny"

    get reports_url, headers: sign_in(@alice)
    assert_response :success, "the ?id= must make no difference"
  end

  # The story the README's "Scoping a list" section promises, end to end: a
  # subject holding ONLY a scoped grant reaches the gated index — no org-wide
  # grant — and scope_for then hands them exactly their subset. Before the
  # record-less gate landed there was no grant combination that produced this:
  # the scoped-only subject was 403'd, and the org grant that got them in made
  # scope_for return every record.
  test "a scoped-only subject reaches the gated index and scope_for narrows to their subset" do
    other = Report.create!(title: "Q4", requested_by: @bob) # never granted to Alice
    viewer = role("Viewer", "reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)

    get reports_url, headers: sign_in(@alice)
    assert_response :success, "a scoped-only subject must reach their index without an org grant"

    # End-to-end, in the response body — not just at the resolver. The gate let
    # her in and the controller's scope_for narrowed the list to her grant.
    assert_equal "Q3", response.body
    assert_no_match(/Q4/, response.body, "the ungranted report must not reach the response")

    # And the resolver half the controller is built on.
    scoped = CurrentScope.resolver.scope_for(subject: @alice, model: Report, permission: "reports#index")
    assert_equal [ @report.id ], scoped.ids
    assert_not_includes scoped.ids, other.id, "an org-wide grant would have leaked this record"
  end

  # A member route whose controller declares no current_scope_record hook: the
  # gate cannot name the record, so it must NOT read that as "collection action,
  # no record" and open up. Alice is scoped on @report only — without the
  # NO_RECORD sentinel she would reach ANY report through this route, which is
  # strictly worse than the 403 she got before the record-less gate existed.
  test "a member route with no record hook fails closed for a scoped grant" do
    other = Report.create!(title: "Q4", requested_by: @bob)
    viewer = role("Viewer", "hookless_member#show")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)

    get hookless_member_url(other), headers: sign_in(@alice)
    assert_response :forbidden, "a member route that cannot name its record must fail closed"
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]

    # Not even the record she IS scoped on — the gate has no way to know which
    # record this route meant, so it refuses either way rather than guess.
    get hookless_member_url(@report), headers: sign_in(@alice)
    assert_response :forbidden
  end

  # The gate reads the DECLARATION, not the route, so no routing DSL option can
  # talk it into a scoped allow. Both of these killed a previous route-reading
  # heuristic: `param: :slug` defeats keying on :id, and `param: :external_id`
  # defeats "any key not suffixed _id".
  test "a member route with a custom param fails closed, whatever the param is named" do
    other = Report.create!(title: "Q4", requested_by: @bob)
    CurrentScope::ScopedRoleAssignment.create!(
      subject: @alice, role: role("Viewer", "slug_reports#show", "external_id_reports#show"),
      resource: @report
    )

    get slug_report_url(other.title), headers: sign_in(@alice)
    assert_response :forbidden, "param: :slug — no hook, so no scoped allow"
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]

    get external_id_report_url(other.title), headers: sign_in(@alice)
    assert_response :forbidden, "param: :external_id — a member param that happens to end in _id"
  end

  # The non-regression on the above: a nested collection's only dynamic segment
  # is the parent's :project_id, which must NOT read as a member route — a
  # scoped-only subject has to keep reaching its index (the whole point of #19).
  test "a nested collection route still reaches its index on a scoped grant" do
    other = Report.create!(title: "Q4", requested_by: @bob)
    project = Project.create!(name: "Apollo")
    viewer = role("Viewer", "nested_reports#index")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: viewer, resource: @report)

    get project_nested_reports_url(project), headers: sign_in(@alice)
    assert_response :success, "a nested collection must not be mistaken for a member route"
    assert_equal "Q3", response.body
    assert_no_match(/Q4/, response.body, "and scope_for must still narrow it")
  end

  test "a member route with no record hook still honors an org-wide grant" do
    # Unchanged: the org path never reads the record, so the sentinel is inert
    # here. Only the scoped paths are affected.
    assign(@alice, role("Member", "hookless_member#show"))

    get hookless_member_url(@report), headers: sign_in(@alice)
    assert_response :success
    assert_equal "Q3", response.body
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
