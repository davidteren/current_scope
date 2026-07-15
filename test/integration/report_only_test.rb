require "test_helper"

# Report-only enforcement (#37): the adoption ramp. A host retrofitting the gem
# onto an existing app mounts the gate, watches what WOULD have been denied, and
# fixes its grants before anything 403s.
#
# The load-bearing tests here are the NEGATIVE ones. Report mode lifts exactly
# the grant-absence wall (:no_grant) and nothing else — the whole design is a
# positive match on one reason, so every other denial must still refuse.
class ReportOnlyTest < ActionDispatch::IntegrationTest
  setup do
    @alice = User.create!(name: "Alice")   # roleless — the retrofit case
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)

    @original_enforcement = CurrentScope.config.enforcement
    @original_sod_actions = CurrentScope.config.sod_actions
    @original_audit = CurrentScope.config.audit
  end

  teardown do
    CurrentScope.config.enforcement = @original_enforcement
    CurrentScope.config.sod_actions = @original_sod_actions
    CurrentScope.config.audit = @original_audit
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }
  def assign(user, role) = CurrentScope::RoleAssignment.create!(subject: user, role: role)

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  # --- R1: :enforce is the default and is byte-for-byte unchanged ---

  test "enforce is the default" do
    assert_equal :enforce, CurrentScope.config.enforcement
  end

  test "under enforce, a roleless subject is still denied exactly as before" do
    CurrentScope.config.enforcement = :enforce

    assert_no_difference -> { CurrentScope::Event.count } do
      get reports_url, headers: sign_in(@alice)
    end
    assert_response :forbidden
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]
  end

  # --- R3/R4: report mode lifts the grant-absence wall and says so ---

  test "under report, a would-be denial proceeds and is reported" do
    CurrentScope.config.enforcement = :report

    get reports_url, headers: sign_in(@alice)

    assert_response :success, "report mode must not 403 the retrofit wall"
    assert_equal "would_deny", response.headers["X-Current-Scope-Reason"]
  end

  test "the would-be denial lands in the ledger, attributed to the subject" do
    CurrentScope.config.enforcement = :report

    assert_difference -> { CurrentScope::Event.where(event: "access.would_deny").count }, 1 do
      get reports_url, headers: sign_in(@alice)
    end

    event = CurrentScope::Event.where(event: "access.would_deny").last
    assert_equal @alice.to_gid.to_s, event.subject
    assert_equal "reports#index", event.details["permission"]
    assert_equal "no_grant", event.details["reason"]
  end

  test "a granted action in report mode is an ordinary allow — no report, no header" do
    CurrentScope.config.enforcement = :report
    assign(@alice, role("Member", "reports#index"))

    assert_no_difference -> { CurrentScope::Event.count } do
      get reports_url, headers: sign_in(@alice)
    end
    assert_response :success
    assert_nil response.headers["X-Current-Scope-Reason"], "a real grant is not a would-be denial"
  end

  # --- The negatives. Report mode is an RBAC adoption ramp, not an off switch ---
  #
  # These hold for TWO independent reasons, and it is worth knowing which is
  # which — mutation-testing the rule showed the difference:
  #
  #   :sod_veto        — reaches the gate and is refused BY the rule here.
  #   :not_full_access — the console skips the gate entirely and answers to
  #   :impersonation_gate — its own check; MutationGuard likewise runs separately.
  #
  # So the last two are structurally out of report mode's reach, not filtered by
  # it. That is a stronger guarantee than the rule, but it means these tests do
  # not pin the rule — ReportOnlyRuleTest below does that.

  test "report mode does NOT relax the SoD veto — the fraud control stands" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]
    assign(@bob, role("Reviewer", "reports#approve")) # @bob initiated @report

    # Relaxing this would let the initiator actually self-approve: a real fraud
    # action executes, not merely a surfaced role gap.
    post approve_report_url(@report), headers: sign_in(@bob)

    assert_response :forbidden
    assert_equal "sod_veto", response.headers["X-Current-Scope-Reason"]
  end

  test "report mode does NOT relax the engine console's 403" do
    CurrentScope.config.enforcement = :report
    assign(@alice, role("Member")) # no full_access

    # Report mode must never hand out the UI where grants are made — that would
    # turn an observation flag into a privilege escalation.
    get current_scope.roles_url, headers: sign_in(@alice)

    assert_response :forbidden
    assert_equal "not_full_access", response.headers["X-Current-Scope-Reason"]
  end

  test "report mode does NOT relax the impersonation gate" do
    CurrentScope.config.enforcement = :report
    original_actor = CurrentScope.config.actor_method
    CurrentScope.config.actor_method = :true_user
    assign(@alice, role("Owner", full_access: true))

    post approve_report_url(@report),
         headers: { "X-User-Id" => @alice.id.to_s, "X-Actor-Id" => @bob.id.to_s }

    assert_response :forbidden
    assert_equal "impersonation_gate", response.headers["X-Current-Scope-Reason"]
  ensure
    CurrentScope.config.actor_method = original_actor
  end

  # --- R3 is absolute: report mode may never raise ---
  #
  # Every current caller of Event.record! is a mutation being performed, where
  # refusing to proceed is correct. This is not one. A retrofitting host that
  # sets audit = :strict and hasn't run the migration is EXACTLY who report mode
  # is for, and they must not get a 500 on every ungranted request.

  # ponytail: plain singleton swap — minitest 6 dropped minitest/mock, and this
  # is not worth a dependency.
  def with_broken_ledger
    singleton = CurrentScope::Event.singleton_class
    original = CurrentScope::Event.method(:record!)
    singleton.define_method(:record!) { |**| raise ActiveRecord::StatementInvalid, "no such table: current_scope_events" }
    yield
  ensure
    singleton.define_method(:record!, original)
  end

  test "report mode still proceeds when the ledger cannot record" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = :strict

    # The retrofitting host that has not run the events migration. Under :strict
    # Event.record! raises by design — correct for a mutation, fatal here.
    with_broken_ledger do
      get reports_url, headers: sign_in(@alice)
    end

    assert_response :success, "an unrecordable observation must not become a 500"
    assert_equal "would_deny", response.headers["X-Current-Scope-Reason"]
  end

  test "report mode proceeds for an anonymous subject, recording nothing" do
    CurrentScope.config.enforcement = :report

    # No ambient subject: nothing to attribute a row to, and Event.record! raises
    # on a nil actor. Still an observation, still non-disruptive.
    assert_no_difference -> { CurrentScope::Event.count } do
      get reports_url
    end
    assert_response :success
    assert_equal "would_deny", response.headers["X-Current-Scope-Reason"]
  end

  test "report mode records nothing when audit is off, and still proceeds" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = false

    assert_no_difference -> { CurrentScope::Event.count } do
      get reports_url, headers: sign_in(@alice)
    end
    assert_response :success
    assert_equal "would_deny", response.headers["X-Current-Scope-Reason"]
  end
end

# The rule itself, unit-tested — because the integration tests above CANNOT pin
# it. Only :no_grant and :sod_veto reach the gate today, so "== :no_grant" and
# "!= :sod_veto" are behaviourally identical right now: mutating the rule to the
# negative form leaves every test above green.
#
# That equivalence is exactly what expires. The positive match is a bet on the
# NEXT denial reason, and the engine has already added two reasons since this
# feature was designed. A negative rule would have been correct on the day it was
# written and would silently start letting a new refusal through — report mode
# relaxing a rule nobody had thought of yet. So the rule gets a test that fails
# the moment it stops being a positive match.
class ReportOnlyRuleTest < ActiveSupport::TestCase
  setup do
    @original = CurrentScope.config.enforcement
    @controller = ReportsController.new
  end
  teardown { CurrentScope.config.enforcement = @original }

  def report_only_denial?(reason) = @controller.send(:report_only_denial?, reason)

  test "under report, only a missing grant is downgraded to an observation" do
    CurrentScope.config.enforcement = :report

    assert report_only_denial?(:no_grant)
    assert_not report_only_denial?(:sod_veto)
  end

  test "a denial reason that does not exist yet is still a denial" do
    CurrentScope.config.enforcement = :report

    # Stands in for the next :not_full_access — a reason invented after this
    # rule was written. It must refuse WITHOUT anyone editing this rule.
    assert_not report_only_denial?(:some_future_refusal),
               "report mode must relax exactly :no_grant — a new reason is a refusal until " \
               "someone deliberately decides otherwise"
  end

  test "under enforce, nothing is downgraded" do
    CurrentScope.config.enforcement = :enforce

    assert_not report_only_denial?(:no_grant)
  end
end

# The config surface. A validating writer, because silently accepting an unknown
# value here means a host believes it is enforcing when it is not — or believes
# it is observing while it 403s its users.
class ReportOnlyConfigTest < ActiveSupport::TestCase
  setup { @original = CurrentScope.config.enforcement }
  teardown { CurrentScope.config.enforcement = @original }

  test "accepts the two modes, as Symbol or String" do
    CurrentScope.config.enforcement = :report
    assert_equal :report, CurrentScope.config.enforcement

    CurrentScope.config.enforcement = "enforce"
    assert_equal :enforce, CurrentScope.config.enforcement
  end

  test "an unknown mode raises, naming what is allowed" do
    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.config.enforcement = :off }
    assert_match "enforce", error.message
    assert_match "report", error.message
  end

  # nil is what `config.enforcement = ENV["..."]` yields when the var is unset —
  # the case a host actually hits. It must fail loud, not crash with an unrelated
  # error class, and not silently disable enforcement.
  test "nil and other non-symbolizable values raise ConfigurationError, not NoMethodError" do
    [ nil, 42, [], false ].each do |bad|
      assert_raises(CurrentScope::ConfigurationError, "enforcement = #{bad.inspect}") do
        CurrentScope.config.enforcement = bad
      end
    end
  end

  test "a rejected assignment leaves the previous mode intact" do
    CurrentScope.config.enforcement = :report
    assert_raises(CurrentScope::ConfigurationError) { CurrentScope.config.enforcement = :nonsense }

    assert_equal :report, CurrentScope.config.enforcement, "a failed write must not half-apply"
  end
end
