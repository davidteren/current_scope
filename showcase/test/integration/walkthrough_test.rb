require "test_helper"

# U12 — the guided "try to commit fraud → refused" walkthrough. Proves refusals
# EXPLAIN themselves and that separation of duties is structural: even a real
# preparer, hiding behind an approver they act-as, cannot approve their own run.
class WalkthroughTest < ActionDispatch::IntegrationTest
  # The walkthrough is wired to the seeded payroll personas by email, so the
  # test builds those exact identities.
  setup do
    @preparer = User.create!(email_address: "payroll.preparer@example.com", password: "password")
    @approver = User.create!(email_address: "payroll.approver@example.com", password: "password")

    base = %w[pay_runs#index pay_runs#show pay_runs#new pay_runs#create]
    preparer_role = CurrentScope::Role.create!(name: "wt preparer")
    preparer_role.update!(permission_keys: base) # NO approve — a preparer never signs off
    approver_role = CurrentScope::Role.create!(name: "wt approver")
    approver_role.update!(permission_keys: base + %w[pay_runs#approve])

    CurrentScope::RoleAssignment.create!(subject: @preparer, role: preparer_role)
    CurrentScope::RoleAssignment.create!(subject: @approver, role: approver_role)

    @pay_run = PayRun.create!(period: "2026-07", label: "July salaries", amount: 84_200, prepared_by: @preparer)
  end

  # Literal paths: after a request into the mounted engine the integration
  # session keeps its SCRIPT_NAME, which would skew the url helpers.
  def sign_in_as_persona(user) = post "/session", params: { email_address: user.email_address, password: "password" }
  def act_as(user) = post "/act_as", params: { id: user.id }
  def approve(run) = post "/pay_runs/#{run.id}/approve"

  test "the walkthrough steps render in order, reachable by the Visitor with no login wall" do
    get "/walkthrough"
    assert_response :success                        # auto-Visitor, not bounced to /session/new
    assert_select "a[href=?]", "/walkthrough/prepared"

    %w[intro prepared approve either].each do |step|
      get "/walkthrough/#{step}"
      assert_response :success
    end
  end

  test "a forced approve as the record's initiator renders the :sod_veto explanation, not a blank 403" do
    sign_in_as_persona(@preparer)                   # the signed-in actor IS the initiator

    approve(@pay_run)

    assert_response :forbidden
    assert_equal "sod_veto", @response.headers["X-Current-Scope-Reason"]
    assert_match(/separation of duties/i, @response.body)
    assert_match(/can never approve it/i, @response.body)
    assert_not @pay_run.reload.approved?
  end

  test "the :either beat: signed-in-as-preparer, acting-as an approver, still cannot approve their own run" do
    sign_in_as_persona(@preparer)                   # REAL actor = preparer (the initiator)
    act_as(@approver)                               # effective subject = approver (holds approve)

    approve(@pay_run)                               # initiator == real actor → vetoed under :either

    assert_response :forbidden
    assert_equal "sod_veto", @response.headers["X-Current-Scope-Reason"]
    assert_match(/separation of duties/i, @response.body)
    assert_not @pay_run.reload.approved?
  end

  test "a forced approve by a persona with no grant renders the :no_grant explanation" do
    approve(@pay_run)                               # Visitor holds no pay_runs#approve

    assert_response :forbidden
    assert_equal "no_grant", @response.headers["X-Current-Scope-Reason"]
    assert_match(/does not grant this action/i, @response.body)
    assert_match(/resets soon/i, @response.body)
    assert_not @pay_run.reload.approved?
  end

  test "an approver who did not initiate the run approves it, and it stamps" do
    sign_in_as_persona(@approver)

    approve(@pay_run)

    assert_redirected_to "/pay_runs/#{@pay_run.id}"
    assert @pay_run.reload.approved?
    assert_equal @approver, @pay_run.approved_by
  end

  test "no mutation happens on GET: the approve path is not reachable by GET" do
    get "/pay_runs/#{@pay_run.id}/approve"          # approve is POST-only (verb-pinned)

    assert_response :not_found
    assert_not @pay_run.reload.approved?
  end

  test "reset-recovery: a missing target record renders the restart page, not a 500" do
    @pay_run.destroy!                               # a later sandbox reset deleted it mid-flow

    get "/walkthrough/prepared"

    assert_response :success
    assert_match(/sandbox was reset/i, @response.body)
    assert_select "a[href=?]", "/walkthrough"       # a link back to the start
  end
end
