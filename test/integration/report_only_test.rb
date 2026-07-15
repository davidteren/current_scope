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

  # The SoD blind spot. Found in review of #59 (cubic P1), and it is the same
  # shape as every other escalation on this engine: a rule that is safe because
  # of a property its existing callers have, reused where that property is gone.
  #
  # The veto is meaningless without a record, so the resolver SKIPS it and
  # returns :none for a nil/Class target (resolver.rb:137). The denial that
  # comes back is therefore :no_grant — which is exactly what report mode
  # downgrades. Result: an SoD-listed action executes while the veto that was
  # supposed to stop it was never asked.
  #
  # In enforce mode :no_grant saved us by accident. Report mode removes the
  # accident.
  test "report mode does NOT let an SoD action through when the veto could not run" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]

    # SodNilController: an approve action whose current_scope_record returns nil.
    # The veto never sees a record, so it never runs.
    post "/sod_nil/approve", headers: sign_in(@bob)

    assert_response :forbidden,
                    "report mode must not downgrade a denial the SoD veto never got to see — " \
                    "the initiator could be this very subject and nobody asked"
    assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]
  end

  test "report mode still reports ordinary would-be denials on non-SoD actions" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]

    # The blind-spot rule must not swallow the feature: a plain collection action
    # is still surveyed while SoD is configured.
    get reports_url, headers: sign_in(@alice)

    assert_response :success
    assert_equal "would_deny", response.headers["X-Current-Scope-Reason"]
  end

  test "report mode reports a would-be denial on an SoD action that HAS a record" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]

    # @alice did not initiate @report, so the veto RAN and passed; the only thing
    # missing is the grant. That is report mode's job, and the blind-spot rule
    # must not over-refuse it.
    post approve_report_url(@report), headers: sign_in(@alice)

    assert_response :success
    assert_equal "would_deny", response.headers["X-Current-Scope-Reason"]
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

  # ponytail: plain singleton swaps — minitest 6 dropped minitest/mock, and this
  # is not worth a dependency.
  def with_broken_ledger(error: nil)
    error ||= ActiveRecord::StatementInvalid.new("no such table: current_scope_events")
    singleton = CurrentScope::Event.singleton_class
    original = CurrentScope::Event.method(:record!)
    singleton.define_method(:record!) { |**| raise error }
    yield
  ensure
    singleton.define_method(:record!, original)
    # The warn-once latch is per-process; a leaked `true` would silently disarm
    # the warning for every later test (and make this suite order-dependent).
    CurrentScope::Guard.reset_ledger_warning!
  end

  # ponytail: a real logger over a StringIO. A hand-rolled fake has to satisfy
  # everything Rails asks of a logger during a request, which it won't.
  def capture_warnings
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.level = Logger::WARN }
    yield
    io.string.lines.map(&:chomp).reject(&:empty?)
  ensure
    Rails.logger = original
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

  # The failure is PERSISTENT, not incidental: :report + audit :strict + no
  # migration fails identically on every single request. Warning per-request
  # floods the log with the same line and buries the one thing the operator needs
  # — that the ledger is empty because the table is missing, and how to fix it.
  #
  # It is also the exact scenario report mode exists for, so it is the one a host
  # is most likely to be in. (#59 review, qodo)
  test "a persistently broken ledger warns once, not once per request" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = :strict

    warnings = capture_warnings do
      with_broken_ledger do
        3.times { get reports_url, headers: sign_in(@alice) }
      end
    end

    ledger_warnings = warnings.grep(/could not record|events table/i)
    assert_equal 1, ledger_warnings.size,
                 "3 identical failures should say it once — got:\n#{ledger_warnings.join("\n")}"
  end

  test "the ledger-failure warning names the fix, not just the exception class" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = :strict

    warnings = capture_warnings do
      with_broken_ledger { get reports_url, headers: sign_in(@alice) }
    end
    warning = warnings.grep(/could not record|events table/i).join

    assert_match(/migrat/i, warning, "a missing table has one fix — say it")
    assert_match "current_scope_events", warning, "name the table so it's greppable"
    assert_match(/allowed|proceed|through/i, warning,
                 "say the request still went through — otherwise this reads as a blocked request")
  end

  test "a ledger failure that is NOT a missing table reports the real error" do
    CurrentScope.config.enforcement = :report

    warnings = capture_warnings do
      with_broken_ledger(error: ActiveRecord::ConnectionNotEstablished.new("connection refused")) do
        get reports_url, headers: sign_in(@alice)
      end
    end
    warning = warnings.join

    assert_match "ConnectionNotEstablished", warning,
                 "telling this host to run migrations would send them after the wrong problem"
    assert_no_match(/run .*migrat/i, warning)
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
    @original_sod_actions = CurrentScope.config.sod_actions
    @controller = ReportsController.new
  end

  teardown do
    CurrentScope.config.enforcement = @original
    CurrentScope.config.sod_actions = @original_sod_actions
  end

  def report_only_denial?(reason, permission = "reports#index", record = nil)
    @controller.send(:report_only_denial?, reason, permission, record)
  end

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

  # The SoD blind spot, at the unit level: :no_grant on an SoD action the veto
  # never ran against does not mean "the veto passed" — it means nobody asked.
  #
  # The set of targets that skip the veto is the RESOLVER's to define, not this
  # rule's. Anything that isn't a record instance skips it (resolver.rb:137), and
  # that includes values a host hands back by mistake — the classic being
  # `params[:id]`, a String. An enumerated guess at "record-less" (nil, a Class)
  # misses exactly those, which is how this fix was wrong on its first draft.
  test "a missing grant on an SoD action the veto could not run against is NOT downgraded" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]

    blind = {
      "nil (collection action)" => nil,
      "NO_RECORD (no hook declared)" => CurrentScope::Guard::NO_RECORD,
      "a Class (allowed_to?(:approve, Report))" => Report,
      "a String — the host returned params[:id]" => "42",
      "an Integer — the host returned params[:id].to_i" => 42,
      "a PORO the host hands back" => Object.new
    }

    blind.each do |describe_it, record|
      assert_not report_only_denial?(:no_grant, "reports#approve", record),
                 "#{describe_it}: the resolver skips the veto here, so :no_grant is not " \
                 "evidence the veto passed — report mode must not speak for a rule that never ran"
    end
  end

  # The rule must not re-derive "did the veto run" — the resolver owns that, and
  # a second copy of the condition is a copy that drifts. This pins them together:
  # for every target, report mode downgrades only when the resolver actually let
  # the veto decide.
  test "the blind spot tracks the resolver's own skip condition, not a guess at it" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]

    [ nil, CurrentScope::Guard::NO_RECORD, Report, "42", 42, Object.new, Report.new ].each do |record|
      veto_ran = CurrentScope.resolver.sod_veto_applies?(permission: "reports#approve", record: record)

      assert_equal veto_ran, report_only_denial?(:no_grant, "reports#approve", record),
                   "downgrading #{record.inspect} must agree with whether the veto ran on it"
    end
  end

  test "a missing grant on an SoD action WITH a record is downgraded — the veto ran and passed" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]

    assert report_only_denial?(:no_grant, "reports#approve", Report.new),
           "the veto saw the record and did not veto; the only thing missing is the grant, " \
           "which is exactly what report mode surveys"
  end

  test "the blind spot is scoped to SoD actions — a plain action with no record still reports" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = %w[approve]

    assert report_only_denial?(:no_grant, "reports#index", nil),
           "a collection action has no record by design — that is not a blind spot"
  end

  test "with SoD off, nothing is a blind spot" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.sod_actions = []

    assert report_only_denial?(:no_grant, "reports#approve", nil),
           "an empty sod_actions makes the veto inert; there is no rule being spoken for"
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

  # Report mode in production is allowed on purpose — surveying real traffic is
  # the point, and a staging run doesn't show you the flows real users take. But
  # "we are not enforcing authorization" fails quietly: nothing breaks, nobody is
  # refused, and the temporary survey silently becomes the permanent posture. So
  # it has to announce itself. (#59 review, qodo)
  # ponytail: plain singleton swaps — minitest 6 dropped minitest/mock, and this
  # isn't worth a dependency. Captures what the boot warning actually said.
  def capture_warnings(production:)
    logged = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |m| logged << m }

    original_logger = Rails.logger
    Rails.logger = logger
    Rails.env.define_singleton_method(:production?) { production }
    yield
    logged.join("\n")
  ensure
    Rails.logger = original_logger
    Rails.env.singleton_class.remove_method(:production?)
  end

  test "report mode in production warns loudly, and still works" do
    warning = capture_warnings(production: true) { CurrentScope.config.enforcement = :report }

    assert_equal :report, CurrentScope.config.enforcement,
                 "prod report mode is deliberate — surveying real traffic is the point, not a mistake to refuse"
    assert_match(/not being enforced/i, warning)
    assert_match "access.would_deny", warning, "the warning must say where to find the gaps"
    assert_match ":enforce", warning, "and how to get out"
  end

  test "enforce in production says nothing" do
    assert_empty capture_warnings(production: true) { CurrentScope.config.enforcement = :enforce },
                 "the safe posture is not news"
  end

  test "report mode outside production says nothing" do
    assert_empty capture_warnings(production: false) { CurrentScope.config.enforcement = :report },
                 "report mode in dev/test is the normal way to use it"
  end

  test "a rejected value in production warns about nothing — it never became a mode" do
    warning = capture_warnings(production: true) do
      assert_raises(CurrentScope::ConfigurationError) { CurrentScope.config.enforcement = :repot }
    end

    assert_empty warning, "the typo raised; there is no report mode to warn about"
  end
end
