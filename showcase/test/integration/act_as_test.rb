require "test_helper"

# The act-as switcher (engine impersonation). An anonymous visitor is
# auto-signed-in as the roleless Visitor and can become any seeded persona in
# one click; the same screen re-renders for that persona's permissions.
class ActAsTest < ActionDispatch::IntegrationTest
  setup do
    @member   = users(:one)   # requests reports(:one)
    @reviewer = users(:two)   # requests reports(:two)
    @report   = reports(:one) # requested by @member

    member_role = CurrentScope::Role.create!(name: "Member")
    member_role.update!(permission_keys: %w[projects#index projects#show reports#index reports#show reports#new reports#create])
    reviewer_role = CurrentScope::Role.create!(name: "Reviewer")
    reviewer_role.update!(permission_keys: member_role.permission_keys + %w[reports#approve])

    CurrentScope::RoleAssignment.create!(subject: @member, role: member_role)
    CurrentScope::RoleAssignment.create!(subject: @reviewer, role: reviewer_role)
  end

  # Literal paths: after a request into the mounted engine the integration
  # session keeps its SCRIPT_NAME, which would skew the url helpers.
  def act_as(user)   = post "/act_as", params: { id: user.id }
  def stop_acting_as = delete "/act_as"

  # The persistent state signal is the banner element, not the flash confirming
  # a click — assert on <span class="acting-as">, which renders iff impersonating.
  def assert_no_banner = assert_select "span.acting-as", false, "expected no acting-as banner"

  test "an anonymous first hit is auto-signed-in as the Visitor, not bounced to login" do
    get root_path

    assert_response :success                     # a page renders — not a 302 to /session/new
    assert cookies[:session_id].present?         # a Visitor session was created
    assert_select "span.signatory", /Visitor/
    assert_no_banner
  end

  test "picking a persona re-renders the screen for that persona's permissions" do
    get report_url(@report)
    assert_response :forbidden                   # Visitor holds no reports#show grant

    act_as(@reviewer)

    get report_url(@report)
    assert_response :success                      # reviewer holds reports#show
    # A control visible only to an approver now appears (approve on a report the
    # reviewer did not request).
    assert_select "form[action=?]", approve_report_path(@report), count: 1
  end

  test "the banner names BOTH identities while impersonating" do
    get root_path
    act_as(@reviewer)

    get reports_url
    assert_response :success
    assert_select "span.acting-as" do |els|
      assert_match @reviewer.email_address, els.text  # who you are acting as
      assert_match "visitor@example.com", els.text    # who you really are
    end
  end

  test "re-picking replaces the impersonated id" do
    get root_path
    act_as(@reviewer)
    act_as(@member)                               # re-pick

    get root_path
    assert_select "span.acting-as", /#{@member.email_address}/

    # Discriminating: the member cannot approve. Had the reviewer stuck, this
    # would redirect (approved) instead of 403.
    post approve_report_url(@report)
    assert_response :forbidden
    assert_not @report.reload.approved?
  end

  test "signing out clears act-as — a fresh visit is not still impersonating" do
    get root_path
    act_as(@reviewer)
    get root_path
    assert_select "span.acting-as", /#{@reviewer.email_address}/  # impersonating now

    delete "/session"                             # sign out the Visitor

    get root_path
    assert_response :success
    assert_no_banner
  end

  test "signing in while acting-as does NOT carry impersonation into the new session" do
    get root_path            # anonymous → auto-signed-in as Visitor
    act_as(@reviewer)        # Visitor now acts as the reviewer

    # The fraud walkthrough signs in WITHOUT signing out first — the auth
    # generator does not rotate the session, so a stale acting-as key would
    # otherwise ride into the authenticated session.
    post "/session", params: { email_address: @member.email_address, password: "password" }

    get report_url(reports(:two))
    assert_response :success           # member holds reports#show
    assert_no_banner

    # Discriminating check: member cannot approve. If the reviewer had leaked
    # in as the effective subject, this approve would succeed instead of 403.
    post approve_report_url(@report)
    assert_response :forbidden
    assert_not @report.reload.approved?
  end

  test "a stale impersonated id clears loudly and continues as Visitor" do
    ghost = User.create!(email_address: "ghost@example.com", password: "password")
    get root_path
    act_as(ghost)
    ghost.destroy!                     # sandbox reset — persona gone, session key now stale

    get root_path
    assert_response :success
    assert_match(/sandbox was reset/i, @response.body)
    assert_no_banner
  end

  test "mutations work while acting-as (config allows writes)" do
    get root_path
    act_as(@reviewer)

    post approve_report_url(@report)   # reviewer approves the member's report
    assert_redirected_to report_url(@report)
    assert @report.reload.approved?
  end

  # Regression (P1): the stamp must record the EFFECTIVE persona, not the real
  # Visitor behind the act-as. The domain-flow tests miss this because they sign
  # in directly (no distinct actor), so the bug only shows under impersonation.
  test "approving while acting-as stamps the persona, not the real Visitor" do
    get root_path
    act_as(@reviewer)

    post approve_report_url(@report)
    assert_redirected_to report_url(@report)

    @report.reload
    assert @report.approved?
    assert_equal @reviewer, @report.approved_by, "the acting persona must be the stamped approver"
    assert_not_equal User.visitor, @report.approved_by
  end

  # Regression (P1): the four-eyes note keys off the effective subject (and the
  # real actor, mirroring the :either SoD gate) — not the Visitor. Acting as the
  # persona that initiated the record must surface the note.
  test "the four-eyes note renders for a record the acting persona initiated" do
    get root_path
    act_as(@member)                    # @member requested @report

    get report_url(@report)
    assert_response :success
    assert_select "div.countersign", /Four-eyes rule/
  end

  test "stopping act-as (DELETE) succeeds while impersonating" do
    get root_path
    act_as(@reviewer)

    stop_acting_as
    assert_response :redirect          # not a 403 from the read-only gate

    get root_path
    assert_no_banner                   # back to Visitor
  end

  test "GET to the act-as routes is rejected (verb-pinned to POST/DELETE)" do
    get "/act_as"                      # only POST (start) and DELETE (stop) are routed
    assert_response :not_found
  end

  test "boundary events are written on start, switch, and stop" do
    get root_path

    assert_difference -> { CurrentScope::Event.where(event: "impersonation.started").count }, 1 do
      act_as(@reviewer)
    end
    assert_equal @reviewer.to_gid.to_s,
      CurrentScope::Event.where(event: "impersonation.started").order(:id).last.target

    # A switch records another start, targeting the new persona.
    assert_difference -> { CurrentScope::Event.where(event: "impersonation.started").count }, 1 do
      act_as(@member)
    end
    assert_equal @member.to_gid.to_s,
      CurrentScope::Event.where(event: "impersonation.started").order(:id).last.target

    assert_difference -> { CurrentScope::Event.where(event: "impersonation.stopped").count }, 1 do
      stop_acting_as
    end
    assert_equal @member.to_gid.to_s,
      CurrentScope::Event.where(event: "impersonation.stopped").order(:id).last.target
  end
end
