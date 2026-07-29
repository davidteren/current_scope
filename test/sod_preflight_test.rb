require "test_helper"

# #133: the boot-time half. An SoD action reaching a model with no
# current_scope_initiator raises on EVERY request — in :report mode as well as
# :enforce — and the host cannot see it until live traffic finds it. SodPreflight
# answers the same question from routes plus declarations, before traffic.
#
# The pins that matter here are the SILENT ones. This is an advisory built on a
# declaration (current_scope_model) that names the collection's type, not the
# member action's record, so over-claiming is the failure mode to guard against
# — the same trap #134 fell into and pinned its way out of.
class SodPreflightTest < ActiveSupport::TestCase
  setup do
    @original_sod_actions = CurrentScope.config.sod_actions
    CurrentScope.reset_catalog!
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
    CurrentScope.reset_catalog!
  end

  def permissions = CurrentScope::SodPreflight.scan.rows.map(&:first)

  test "the default config finds nothing — SoD is opt-in, so this costs nothing" do
    CurrentScope.config.sod_actions = []

    assert_empty CurrentScope::SodPreflight.scan.rows
  end

  test "names a routed SoD action whose declared model defines no initiator" do
    # DocumentsController declares current_scope_model = Document, and Document
    # (the STI base) deliberately defines no current_scope_initiator.
    CurrentScope.config.sod_actions = %w[show]

    assert_includes permissions, "documents#show"
    assert_equal Document, CurrentScope::SodPreflight.scan.rows.find { |p, _| p == "documents#show" }.last
  end

  test "stays silent about a declared model that DOES define an initiator" do
    # Same config, and reports#show is routed by a controller declaring
    # current_scope_model = Report, which defines current_scope_initiator.
    CurrentScope.config.sod_actions = %w[show]

    refute_includes permissions, "reports#show"
  end

  # The coverage gap, pinned rather than left to be rediscovered as a bug.
  # Admin::ReportsController routes an SoD action and declares NO
  # current_scope_model, so nothing here can say which model it gates. Absent
  # from the list is NOT cleared, which is why the report-mode ledger row exists
  # as the traffic-found half.
  test "a controller declaring no current_scope_model is absent, not cleared" do
    CurrentScope.config.sod_actions = %w[approve]

    refute_includes permissions, "admin/reports#approve"
    assert_empty CurrentScope::SodPreflight.scan.rows,
                 "no dummy controller declares a model for an approve action — " \
                 "guessing one from the route key is exactly what #134 refuted"
  end

  test "a non-SoD action is never inspected, however its model is declared" do
    CurrentScope.config.sod_actions = %w[approve]

    refute_includes permissions, "documents#index"
    refute_includes permissions, "documents#show"
  end

  test "warn! says nothing when there is nothing to say" do
    CurrentScope.config.sod_actions = []

    assert_empty capture_warn_log { CurrentScope::SodPreflight.warn! }
  end

  test "warn! names the action, the model, the fix, and its own limits" do
    CurrentScope.config.sod_actions = %w[show]

    logs = capture_warn_log { CurrentScope::SodPreflight.warn! }

    assert_match "documents#show", logs
    assert_match "Document defines no current_scope_initiator", logs
    assert_match ":report", logs, "a host in report mode must learn this is not downgraded there"
    assert_match "This list is PARTIAL", logs,
                 "an advisory that reads as a verdict is how a diagnostic starts being trusted " \
                 "for something it cannot prove"
  end

  # Host code runs inside this check (an instance method on a controller built
  # outside a request). A hook that raises is a coverage gap, never a boot
  # failure — and never a finding either, because a raise proves nothing.
  # Two assertions, and the second is the one that matters. Asserting only that
  # the broken controller is absent passes just as well when the WHOLE run blew
  # up and returned [] — the reviewer proved that by deleting declared_model_for's
  # rescue and watching this test stay green. So a healthy controller has to be
  # in the same run, and it has to still report. (#133 review)
  test "a raising controller is skipped without blinding the rest of the run" do
    CurrentScope.config.sod_actions = %w[show]

    # hookless_member also routes `show`, so it IS inspected under this config —
    # which is what makes it a usable stand-in for a controller whose own code
    # blows up while being read.
    HooklessMemberController.define_singleton_method(:new) { |*| raise "the host's own hook blew up" }

    result = CurrentScope::SodPreflight.scan
    found = result.rows

    assert_empty found.select { |p, _| p.start_with?("hookless_member#") },
                 "an unanswerable controller must not become a finding"
    assert_includes found.map(&:first), "documents#show",
                    "one broken controller must not suppress every other finding — " \
                    "isolation is what declared_model_for's own rescue is for"
    assert result.degraded?
  ensure
    # Removing the override restores the inherited Class#new — no saved method
    # to put back, and nothing left behind for the next test in this process.
    HooklessMemberController.singleton_class.send(:remove_method, :new)
  end

  # KTD-2, and the reason this test exists at all: moving the boot check to
  # config.to_prepare passes the whole suite and BREAKS EVERY GATED REQUEST in a
  # real host. The preflight reads CurrentScope.catalog, the catalog memoizes its
  # derivation, and to_prepare can run before the routes are drawn — so the
  # engine caches an empty permission set for the life of the process and every
  # gated request then raises "not in the permission catalog". Measured in the
  # dummy: 44 catalog keys on after_routes_loaded, 0 on to_prepare.
  #
  # The suite stays green through that because sod_actions defaults to [] and the
  # preflight returns before touching the catalog — so the damage is invisible
  # here and lands only on a host that opted into SoD, which is every host this
  # feature is for. Hence a pin on the CAUSE: nothing on to_prepare may derive
  # the catalog.
  test "the to_prepare chain never derives the permission catalog (#133 KTD-2)" do
    # to_prepare also calls reset_scopeable_registry!, and in a test process that
    # is DESTRUCTIVE: the registry is filled by `include CurrentScope::Scopeable`
    # in a model's class body, and prepare! does not unload constants — so those
    # bodies never re-run and the registry stays empty for every later test. It
    # cost the picker suite 11 failures on seed 22 before this snapshot existed.
    # Restore it by hand; nothing else to_prepare resets is a latch that matters.
    scopeable = CurrentScope.scopeable_registry.dup
    CurrentScope.config.sod_actions = %w[show]
    CurrentScope.reset_catalog!

    Rails.application.reloader.prepare!

    refute CurrentScope.catalog.instance_variable_defined?(:@keys),
           "a to_prepare block derived the permission catalog. If routes are not " \
           "drawn yet at that point, the empty derivation is MEMOIZED and every " \
           "gated request raises for the rest of the process. Move the read to " \
           "after_routes_loaded."
  ensure
    CurrentScope.reset_scopeable_registry!
    scopeable&.each { |name| CurrentScope.register_scopeable(name) }
  end

  # THE FEATURE'S HEADLINE HALF WAS UNPINNED. Every test above exercises the
  # module; none asserted the engine ever CALLS it. A reviewer deleted the whole
  # `initializer "current_scope.sod_preflight"` block and ran the suite: 724
  # runs, 0 failures. So a bad merge — or a Rails change to when
  # :after_routes_loaded fires — could remove the boot warning entirely and
  # every test would still pass. Two assertions: the wiring exists, and firing
  # the hook actually produces the warning.
  test "the engine wires the preflight to the routes-loaded hook (#133)" do
    assert_includes Rails.application.initializers.map(&:name),
                    "current_scope.sod_preflight",
                    "the boot half of #133 is this initializer; without it the feature is " \
                    "a module nobody calls"
  end

  test "firing the routes-loaded hook emits the preflight warning (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    logs = capture_warn_log do
      ActiveSupport.run_load_hooks(:after_routes_loaded, Rails.application)
    end

    assert_match "separation-of-duties preflight", logs,
                 "the registered hook must actually reach warn! — asserting the initializer " \
                 "exists proves it was registered, not that it does anything"
    assert_match "documents#show", logs
  end

  # cubic: the preflight ran host constructors for every declared model at boot.
  # A model that is FINE must now never be built — the class-level answer settles
  # it — while a model about to be NAMED still is, because the class check
  # diverges from the resolver exactly where it would produce a false accusation.
  test "a compliant model is never instantiated (#133)" do
    CurrentScope.config.sod_actions = %w[show]
    built = 0
    Report.define_singleton_method(:new) { |*a, **k, &b| built += 1; super(*a, **k, &b) }

    CurrentScope::SodPreflight.scan

    assert_equal 0, built,
                 "Report defines current_scope_initiator as a real method, so the class " \
                 "answers it — running host initialize/after_initialize to learn that is a " \
                 "side effect at boot for nothing"
  ensure
    Report.singleton_class.send(:remove_method, :new)
  end

  test "a hook reachable only through respond_to_missing? is not falsely accused (#133)" do
    CurrentScope.config.sod_actions = %w[show]
    # Document has no real current_scope_initiator, so the class check says
    # "missing" — the one case where the instance check must still run, because
    # this is the moment the module would name a model.
    Document.define_method(:respond_to_missing?) { |name, _priv = false| name.to_sym == :current_scope_initiator }

    refute_includes permissions, "documents#show",
                    "the instance check is the confirmation before an accusation; skipping " \
                    "it here would name a model that answers the hook at runtime"
  ensure
    Document.send(:remove_method, :respond_to_missing?)
  end

  # cubic: the top-level rescue used to return a fresh empty Result, so a failure
  # partway through the walk discarded every finding collected before it. In a
  # large app one bad controller would hide every earlier SoD miss from both
  # surfaces — the exact case this check exists to surface.
  test "a failure partway through the walk keeps what was already found (#133)" do
    CurrentScope.config.sod_actions = %w[show]
    singleton = CurrentScope::SodPreflight.singleton_class
    original = CurrentScope::SodPreflight.method(:declared_model_for)
    # `slug_reports` sorts after `documents`, so documents#show is already
    # collected when this blows up. Raising from declared_model_for (rather than
    # inside it) is what escapes the helper's own rescue and reaches the walk.
    singleton.define_method(:declared_model_for) do |path, reflection, skipped|
      raise "blew up mid-walk" if path == "slug_reports"

      original.call(path, reflection, skipped)
    end

    result = CurrentScope::SodPreflight.scan

    assert_includes result.rows.map(&:first), "documents#show",
                    "findings collected before the failure must survive it"
    assert result.degraded?, "and the run must still say it is incomplete"
  ensure
    singleton.define_method(:declared_model_for, original)
    singleton.send(:private, :declared_model_for)
  end

  # The model half of the degrade path. defines_initiator? answers TRUE when it
  # cannot tell, which CLEARS the model — so an uninstantiable model (no database
  # connection during an asset precompile, a custom initialize) silently reads as
  # compliant. Deliberate ("prove or stay silent"), but it is the one degrade that
  # makes the list quieter rather than noisier, so it is pinned and named in the
  # caveat rather than left for someone to discover.
  test "a model that cannot be instantiated is passed over, not flagged (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    Document.define_singleton_method(:new) { |*| raise "no connection" }

    result = CurrentScope::SodPreflight.scan

    refute_includes result.rows.map(&:first), "documents#show",
                    "an unanswerable check must not become a finding"
    assert result.degraded?,
           "the operator has to be able to tell this list is incomplete"
  ensure
    Document.singleton_class.send(:remove_method, :new)
  end

  # Silence is only honest when the run was clean. A container that boots before
  # its database is reachable fails every check, finds nothing, and would
  # otherwise print nothing at all — a vacuous all-clear on the surface a host
  # reads at deploy time.
  test "warn! speaks when it found nothing BECAUSE it could not look (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    Document.define_singleton_method(:new) { |*| raise "no connection" }
    Report.define_singleton_method(:new) { |*| raise "no connection" }

    logs = capture_warn_log { CurrentScope::SodPreflight.warn! }

    assert_match(/not able to look properly/, logs)
    assert_match(/Do NOT read that as an all-clear/, logs)
  ensure
    Document.singleton_class.send(:remove_method, :new)
    Report.singleton_class.send(:remove_method, :new)
  end

  # The third variant of the vacuous all-clear, and the only one that is not an
  # error state: every routed SoD controller declares no current_scope_model, so
  # findings is empty and nothing FAILED — the run simply read nothing. A flat
  # "none found" there is a confident answer off an empty inspection.
  test "warn! refuses an all-clear when it inspected nothing at all (#133)" do
    # Five controllers route `approve`; exactly one (ReportsController) declares
    # current_scope_model. Drop that declaration and the run is fully in scope
    # and inspects zero — the shape of a host that never adopted #50, which is
    # exactly the host doing a rollout bake.
    CurrentScope.config.sod_actions = %w[approve]
    ReportsController.send(:remove_method, :current_scope_model)

    logs = capture_warn_log { CurrentScope::SodPreflight.warn! }

    result = CurrentScope::SodPreflight.scan
    assert_equal 0, result.inspected
    assert_operator result.in_scope, :>, 0
    assert result.blind?, "nothing read is not a clean run"
    assert_match(/inspected NONE/, logs)
    assert_match(/Do NOT read that as an all-clear/, logs)
  ensure
    ReportsController.send(:define_method, :current_scope_model) { Report }
    ReportsController.send(:private, :current_scope_model)
  end

  test "the result reports what was actually read (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    result = CurrentScope::SodPreflight.scan

    assert_operator result.inspected, :>, 0
    assert_operator result.in_scope, :>=, result.inspected,
                    "in_scope counts every routed SoD action; inspected only those whose " \
                    "controller declared a model"
    refute result.blind?, "a run that read something and skipped nothing is not blind"
  end

  # qodo: `inspected` only counts a declaration that was successfully READ, so a
  # run whose controller checks ALL blew up has inspected == 0 and in_scope > 0
  # — identical numbers to a run that simply had nothing to read. Explaining it
  # as "none of those controllers declares current_scope_model" then sends an
  # operator off to add declarations while their hook is the thing raising.
  #
  # The earlier degraded test did not catch this: it makes the MODEL checks fail,
  # which happens after `inspected` has already been incremented.
  test "a run whose controller checks all failed says SKIPPED, not 'no declarations' (#133)" do
    CurrentScope.config.sod_actions = %w[show]
    singleton = CurrentScope::SodPreflight.singleton_class
    original = CurrentScope::SodPreflight.method(:declared_model_for)
    singleton.define_method(:declared_model_for) do |path, _reflection, skipped|
      skipped << [ path, RuntimeError.new("the host's hook blew up") ]
      nil
    end

    result = CurrentScope::SodPreflight.scan
    logs = capture_warn_log { CurrentScope::SodPreflight.warn!(result) }

    assert_equal 0, result.inspected
    assert_operator result.in_scope, :>, 0
    assert result.degraded?

    assert_match(/not able to look properly/, logs)
    refute_match(/none of those controllers declares current_scope_model/, logs,
                 "the numbers are identical to a nothing-to-read run; only degraded? tells " \
                 "them apart, and naming the wrong cause sends the operator to the wrong fix")
  ensure
    singleton.define_method(:declared_model_for, original)
    singleton.send(:private, :declared_model_for)
  end

  # The two remedies are not coequal on a list that can be wrong: defining the
  # hook wires a control, removing the action DELETES one.
  test "the fix line leads with the hook, not with disabling the veto (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    logs = capture_warn_log { CurrentScope::SodPreflight.warn! }

    assert_operator logs.index("define current_scope_initiator"), :<,
                    logs.index("remove it from config.sod_actions"),
                    "an advisory that can be wrong must not offer turning off four-eyes first"
    assert_match(/removes the control rather than wiring it/, logs)
  end

  test "a clean run does not report itself as degraded (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    refute CurrentScope::SodPreflight.scan.degraded?
  end

  # The state that used to make "never run" answerable at all is gone: the
  # answers ride on the Result, so there is no module flag to read before a run
  # and no fail-closed special case to maintain. This pins that the module keeps
  # no run state — the defect class, not one instance of it.
  test "the module holds no run state between scans (#133)" do
    CurrentScope.config.sod_actions = %w[show]
    CurrentScope::SodPreflight.scan

    leaked = CurrentScope::SodPreflight.instance_variables - [ :@models_loaded ]

    assert_empty leaked,
                 "a scan's answers belong to the scan; state left on the singleton is what " \
                 "made call order matter and 'never run' read as clean"
  end

  # A bug in THIS module must not be reported as a host misconfiguration — and
  # must not take a host's boot down either. It used to re-raise, copying a
  # sibling that is only ever called from a rake task; this module runs from an
  # engine initializer, so the same convention broke boot over a diagnostic.
  # Both halves are pinned: it survives, and it says whose bug it is.
  test "a NoMethodError from our own code is attributed, not raised (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    # A catalog that cannot answer `grouped` stands in for any slip inside this
    # module's own walk. Host code never reaches this rescue — the helpers own
    # it and carry the controller or model as the subject.
    singleton = CurrentScope.singleton_class
    original = CurrentScope.method(:catalog)
    singleton.define_method(:catalog) { Object.new }

    result = nil
    assert_nothing_raised { result = CurrentScope::SodPreflight.scan }

    assert result.degraded?, "our own bug must still mark the run incomplete"
    summary = CurrentScope::SodPreflight.skip_summary(result)
    assert_match(/a bug in current_scope/, summary)
    assert_match(/not from your app/, summary,
                 "blaming host configuration for our bug sends them after the wrong thing")
  ensure
    singleton.define_method(:catalog, original)
  end

  # The boot surface is the one that made the old re-raise a real problem.
  test "a bug in the scan cannot break the boot warning (#133)" do
    CurrentScope.config.sod_actions = %w[show]
    singleton = CurrentScope.singleton_class
    original = CurrentScope.method(:catalog)
    singleton.define_method(:catalog) { Object.new }

    logs = nil
    assert_nothing_raised { logs = capture_warn_log { CurrentScope::SodPreflight.warn! } }

    assert_match(/a bug in current_scope/, logs)
  ensure
    singleton.define_method(:catalog, original)
  end

  private

  def capture_warn_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
