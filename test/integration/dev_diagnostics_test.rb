require "test_helper"

# ponytail: a real logger over a StringIO — a hand-rolled fake has to satisfy
# everything Rails asks of a logger mid-request, and won't. One definition,
# shared by every class here. (#61 review, cubic)
module DiagnosticsLogCapture
  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.level = Logger::WARN }
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def nudges(log) = log.scan(/\[CurrentScope\][^\n]*/)
end

# Dev diagnostics (#41). Three silent failure modes that now tell on themselves.
#
# Every one is LOG-ONLY. The tests that matter most here are the ones proving
# that: a diagnostic that changes a decision is a bug, not a diagnostic.
class DevDiagnosticsTest < ActionDispatch::IntegrationTest
  include DiagnosticsLogCapture
  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)

    @original = {
      inert: CurrentScope.config.warn_on_inert_scoped_grant,
      sod: CurrentScope.config.warn_on_nil_sod_record,
      derivation: CurrentScope.config.warn_on_cross_controller_derivation,
      sod_actions: CurrentScope.config.sod_actions
    }
  end

  teardown do
    CurrentScope.config.warn_on_inert_scoped_grant = @original[:inert]
    CurrentScope.config.warn_on_nil_sod_record = @original[:sod]
    CurrentScope.config.warn_on_cross_controller_derivation = @original[:derivation]
    CurrentScope.config.sod_actions = @original[:sod_actions]
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def scoped(user, role, record) = CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: record)

  # --- The inert scoped grant: keyed on NO_RECORD, not nil ---

  test "fires when a controller with a member action declares no record hook" do
    # HooklessMemberController: a member action (/hookless_member/:id) whose
    # controller never declares current_scope_record. The gate can't name the
    # record, so a scoped grant that would have matched can't apply.
    scoped(@alice, role("Editor", "hookless_member#show"), @report)

    log = capture_log { get "/hookless_member/#{@report.id}", headers: sign_in(@alice) }

    assert_response :forbidden, "the nudge must not change the outcome — it still fails closed"
    assert_equal 1, nudges(log).grep(/scoped grant/).size
    assert_match "current_scope_record", log, "name the missing thing, not just the symptom"
  end

  # The message must claim only what the predicate proves. scoped_grant_exists?
  # has no resource filter — it can't, the missing record IS the bug — so it shows
  # a matching grant exists on SOME record, not that it would have applied to
  # whichever record this action meant. Saying "would satisfy it" overstates that,
  # and overstating is how a diagnostic earns being ignored. (#61 review, qodo)
  test "the message does not claim the grant definitely would have applied" do
    scoped(@alice, role("Editor", "hookless_member#show"), @report)

    log = capture_log { get "/hookless_member/#{@report.id}", headers: sign_in(@alice) }

    assert_match(/on some record/i, log, "say where the grant is known to be: somewhere")
    assert_no_match(/grant that would satisfy it/i, log,
                    "the predicate cannot prove the grant is on THIS action's record")
    assert_match(/if the subject holds the grant on the record in question/i, log,
                 "name the condition under which the advice actually fixes it")
  end

  # The rot pin. Plan 023 guards this nudge on `record.nil?`; #49 made a declared
  # nil ALLOW when a scoped role ticks the key, so there is no denial to nudge
  # about and firing here would hit every legitimate collection request.
  test "does NOT fire for a declared nil — since #49 that is an ALLOW, not an inert grant" do
    scoped(@alice, role("Reader", "reports#index"), @report)

    log = capture_log { get reports_url, headers: sign_in(@alice) }

    assert_response :success,
                    "a declared nil + a scoped role ticking the key opens the gate (#49) — " \
                    "if this ever 403s again, the record-less scoped branch regressed"
    assert_empty nudges(log).grep(/scoped grant/), "nothing is inert here; the grant applied"
  end

  test "does NOT fire when the subject holds no scoped grant at all — that is a real deny" do
    log = capture_log { get "/hookless_member/#{@report.id}", headers: sign_in(@alice) }

    assert_response :forbidden
    assert_empty nudges(log).grep(/scoped grant/),
                 "no grant exists, so nothing is inert — this deny is the system working"
  end

  test "does NOT fire on a denial for any reason other than :no_grant" do
    CurrentScope.config.sod_actions = %w[approve]
    scoped(@bob, role("Approver", "reports#approve"), @report) # @bob initiated it

    log = capture_log { post approve_report_url(@report), headers: sign_in(@bob) }

    assert_response :forbidden
    assert_equal "sod_veto", response.headers["X-Current-Scope-Reason"]
    assert_empty nudges(log).grep(/scoped grant/), "the veto refused this; the grant is not inert"
  end

  test "does NOT fire when the flag is off, and the resolver is never asked" do
    CurrentScope.config.warn_on_inert_scoped_grant = false
    scoped(@alice, role("Editor", "hookless_member#show"), @report)

    calls = 0
    counter = ->(**) { calls += 1; false }
    CurrentScope.resolver.singleton_class.define_method(:scoped_grant_exists?, counter)

    log = capture_log { get "/hookless_member/#{@report.id}", headers: sign_in(@alice) }

    assert_response :forbidden
    assert_empty nudges(log)
    assert_equal 0, calls, "the flag must short-circuit BEFORE the query — this is the deny path"
  ensure
    CurrentScope.resolver.singleton_class.remove_method(:scoped_grant_exists?)
  end

  # --- R4: log-only. The whole feature is worthless if it can change a decision ---

  test "the outcome is byte-for-byte identical with diagnostics on and off" do
    scoped(@alice, role("Editor", "hookless_member#show"), @report)

    CurrentScope.config.warn_on_inert_scoped_grant = true
    capture_log { get "/hookless_member/#{@report.id}", headers: sign_in(@alice) }
    on = [ response.status, response.headers["X-Current-Scope-Reason"], response.body ]

    CurrentScope.config.warn_on_inert_scoped_grant = false
    capture_log { get "/hookless_member/#{@report.id}", headers: sign_in(@alice) }
    off = [ response.status, response.headers["X-Current-Scope-Reason"], response.body ]

    assert_equal off, on
  end

  # --- The advisory boundary: nudges live at the gate, never on allowed_to? ---

  test "the inert-grant nudge never fires on an advisory check" do
    scoped(@alice, role("Editor", "hookless_member#show"), @report)

    log = capture_log do
      CurrentScope::Current.user = @alice
      CurrentScope.allowed?("hookless_member#show", subject: @alice)
    end

    assert_empty nudges(log).grep(/scoped grant/),
                 "advisory checks answer questions; they aren't a gate refusing anyone"
  ensure
    CurrentScope::Current.reset
  end
end

# The nudge's guards, unit-tested — because the integration tests above CANNOT
# pin the reason guard, and a mutation run proved it: deleting
# `return unless reason == :no_grant` leaves every test up there green.
#
# The cause is that the guards mask each other. With NO_RECORD, :no_grant is the
# only reason reachable today — :sod_veto needs a record to veto against,
# :impersonation_gate refuses before the gate runs, and :not_full_access skips
# the gate entirely. So no integration test can construct the case.
#
# That makes the reason guard unreachable-but-load-bearing: it is a bet on the
# NEXT denial reason, exactly like report mode's positive match, and the engine
# has added two reasons in a month. A new reason arriving alongside NO_RECORD
# would otherwise get "you hold a scoped grant, add your record hook" — advice
# aimed at a problem it doesn't have. Untestable guards rot; this one gets a test.
class InertScopedGrantGuardsTest < ActiveSupport::TestCase
  include DiagnosticsLogCapture
  setup do
    @original = CurrentScope.config.warn_on_inert_scoped_grant
    CurrentScope.config.warn_on_inert_scoped_grant = true
    @alice = User.create!(name: "Alice")
    @report = Report.create!(title: "Q3", requested_by: User.create!(name: "B"))
    @controller = HooklessMemberController.new

    role = CurrentScope::Role.create!(name: "Editor")
    role.role_permissions.create!(permission_key: "hookless_member#show")
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: role, resource: @report)
    CurrentScope::Current.user = @alice
  end

  teardown do
    CurrentScope.config.warn_on_inert_scoped_grant = @original
    CurrentScope::Current.reset
  end

  def nudge(reason, record = CurrentScope::Guard::NO_RECORD)
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.level = Logger::WARN }
    @controller.send(:nudge_on_inert_scoped_grant, "hookless_member#show", record, reason)
    io.string
  ensure
    Rails.logger = original
  end

  test "nudges on the case it exists for" do
    assert_match(/scoped grant/, nudge(:no_grant))
  end

  test "a denial reason that does not exist yet gets no advice" do
    # Stands in for the next :not_full_access — invented after this was written.
    assert_empty nudge(:some_future_refusal),
                 "this nudge only knows why a :no_grant with no record happens; a new reason " \
                 "is a different problem and guessing at it sends people the wrong way"
  end

  test "says nothing when the gate had a real record" do
    assert_empty nudge(:no_grant, @report), "the grant applied or didn't on its merits — nothing is inert"
  end

  test "says nothing for a declared nil" do
    assert_empty nudge(:no_grant, nil),
                 "a declared nil is the host stating there's no record here — since #49 a scoped " \
                 "role ticking the key opens that gate, so this deny isn't the inert case"
  end
end

# U3: short-form derivation vs the gate. Unit-level — it's a pure function.
#
# The signal here is AMBIGUOUS and can't be made precise: a DashboardController
# rendering Reports (foot-gun) and a DocumentsController linking to a report
# (correct) hand `permission_key` byte-identical inputs. So the nudge is hedged
# and warns once per site, rather than asserting a bug it can't prove.
class KeyDerivationNudgeTest < ActiveSupport::TestCase
  include DiagnosticsLogCapture

  setup do
    @original = CurrentScope.config.warn_on_cross_controller_derivation
    CurrentScope.config.warn_on_cross_controller_derivation = true
    CurrentScope.reset_cross_controller_warnings!
    @report = Report.create!(title: "Q3", requested_by: User.create!(name: "B"))
  end

  teardown do
    CurrentScope.config.warn_on_cross_controller_derivation = @original
    CurrentScope.reset_cross_controller_warnings!
  end

  test "warns when the derived key diverges from what the current controller gates" do
    log = capture_log do
      key = CurrentScope.permission_key(:show, record: @report, controller_path: "documents")
      assert_equal "reports#show", key, "the derived key is unchanged — this is log-only"
    end

    assert_match "reports#show", log
    assert_match "documents#show", log, "name the key the gate here actually enforces"
  end

  # The honesty requirement. An earlier draft asserted "they disagree" — which is
  # a false statement for a documents view legitimately linking to a report, and
  # it would have fired on every row of the list.
  test "the message admits it cannot tell which reading is right" do
    log = capture_log { CurrentScope.permission_key(:show, record: @report, controller_path: "documents") }

    assert_match(/if you meant this controller's own gate/i, log)
    assert_match(/asking about a different resource/i, log)
    assert_match(/expected/i, log, "the legitimate reading must be named as legitimate, not implied to be a bug")
  end

  # One line per distinct site is a hint; one per row is noise, and noise is how
  # a diagnostic teaches people to filter it out.
  test "warns once per site, not once per call" do
    log = capture_log do
      5.times { CurrentScope.permission_key(:show, record: @report, controller_path: "documents") }
    end

    assert_equal 1, nudges(log).size, "5 identical calls, one warning"
  end

  test "a different site gets its own warning" do
    log = capture_log do
      CurrentScope.permission_key(:show, record: @report, controller_path: "documents")
      CurrentScope.permission_key(:destroy, record: @report, controller_path: "documents")
    end

    assert_equal 2, nudges(log).size, "different action, different site, still worth saying once"
  end

  # The dedup key carries the RECORD TYPE, not just the gate key. One controller
  # action asking about two different record types is two different divergences
  # with two different answers — swallowing the second would hide it behind the
  # first for the life of the process.
  test "the same controller action asking about a different record type warns again" do
    project = Project.create!(name: "Apollo")

    log = capture_log do
      CurrentScope.permission_key(:show, record: @report, controller_path: "documents")
      CurrentScope.permission_key(:show, record: project, controller_path: "documents")
    end

    assert_equal 2, nudges(log).size,
                 "documents#show vs reports#show and documents#show vs projects#show are " \
                 "different facts — the second must not be swallowed by the first"
    assert_match "reports#show", nudges(log)[0]
    assert_match "projects#show", nudges(log)[1]
  end

  test "does NOT warn when the current controller does not route that action at all" do
    # A projects view asking about a report. projects routes nothing, so there is
    # no second key in play — nothing can disagree with anything.
    log = capture_log { CurrentScope.permission_key(:approve, record: @report, controller_path: "projects") }

    assert_empty nudges(log)
  end

  test "does NOT warn when the controller already handles the record type" do
    log = capture_log do
      key = CurrentScope.permission_key(:show, record: @report, controller_path: "admin/reports")
      assert_equal "admin/reports#show", key
    end

    assert_empty nudges(log), "path ends in the route key — gate and view agree by construction"
  end

  test "does NOT warn when the flag is off" do
    CurrentScope.config.warn_on_cross_controller_derivation = false

    log = capture_log { CurrentScope.permission_key(:show, record: @report, controller_path: "documents") }

    assert_empty nudges(log)
  end

  test "the derived key is identical whether the nudge fires or not" do
    CurrentScope.config.warn_on_cross_controller_derivation = true
    on = CurrentScope.permission_key(:show, record: @report, controller_path: "documents")
    CurrentScope.config.warn_on_cross_controller_derivation = false
    off = CurrentScope.permission_key(:show, record: @report, controller_path: "documents")

    assert_equal off, on, "log-only means log-only"
  end
end

# U1: the env-aware default. The default IS the feature — a diagnostic nobody
# knows about helps nobody, and the issue's premise is that these ship off and
# the teams who need them never find them.
class DiagnosticsDefaultsTest < ActiveSupport::TestCase
  FLAGS = %i[warn_on_nil_sod_record warn_on_inert_scoped_grant warn_on_cross_controller_derivation].freeze

  def with_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  test "all three default ON in development and test" do
    %w[development test].each do |env|
      with_env(env) do
        config = CurrentScope::Configuration.new
        FLAGS.each { |f| assert config.public_send(f), "#{f} should default on in #{env}" }
      end
    end
  end

  test "all three default OFF in production" do
    with_env("production") do
      config = CurrentScope::Configuration.new
      FLAGS.each { |f| assert_not config.public_send(f), "#{f} must not log on a prod host's dime" }
    end
  end

  # A staging env reports itself as neither development nor test. Diagnostics off
  # is the conservative side for a log line on someone else's box.
  test "an env that is neither development nor test defaults OFF" do
    with_env("staging") do
      config = CurrentScope::Configuration.new
      FLAGS.each { |f| assert_not config.public_send(f), "#{f} should be off in staging" }
    end
  end

  test "a host override beats the default in either direction" do
    with_env("production") do
      config = CurrentScope::Configuration.new
      FLAGS.each do |f|
        config.public_send("#{f}=", true)
        assert config.public_send(f), "#{f} must be forceable on in production"
      end
    end

    with_env("test") do
      config = CurrentScope::Configuration.new
      FLAGS.each do |f|
        config.public_send("#{f}=", false)
        assert_not config.public_send(f)
      end
    end
  end
end
