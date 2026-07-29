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

  def permissions = CurrentScope::SodPreflight.findings.map(&:first)

  test "the default config finds nothing — SoD is opt-in, so this costs nothing" do
    CurrentScope.config.sod_actions = []

    assert_empty CurrentScope::SodPreflight.findings
  end

  test "names a routed SoD action whose declared model defines no initiator" do
    # DocumentsController declares current_scope_model = Document, and Document
    # (the STI base) deliberately defines no current_scope_initiator.
    CurrentScope.config.sod_actions = %w[show]

    assert_includes permissions, "documents#show"
    assert_equal Document, CurrentScope::SodPreflight.findings.find { |p, _| p == "documents#show" }.last
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
    assert_empty CurrentScope::SodPreflight.findings,
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

    found = CurrentScope::SodPreflight.findings

    assert_empty found.select { |p, _| p.start_with?("hookless_member#") },
                 "an unanswerable controller must not become a finding"
    assert_includes found.map(&:first), "documents#show",
                    "one broken controller must not suppress every other finding — " \
                    "isolation is what declared_model_for's own rescue is for"
    assert CurrentScope::SodPreflight.degraded?
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

  # The model half of the degrade path. defines_initiator? answers TRUE when it
  # cannot tell, which CLEARS the model — so an uninstantiable model (no database
  # connection during an asset precompile, a custom initialize) silently reads as
  # compliant. Deliberate ("prove or stay silent"), but it is the one degrade that
  # makes the list quieter rather than noisier, so it is pinned and named in the
  # caveat rather than left for someone to discover.
  test "a model that cannot be instantiated is passed over, not flagged (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    Document.define_singleton_method(:new) { |*| raise "no connection" }

    refute_includes permissions, "documents#show",
                    "an unanswerable check must not become a finding"
    assert CurrentScope::SodPreflight.degraded?,
           "the operator has to be able to tell this list is incomplete"
  ensure
    Document.singleton_class.send(:remove_method, :new)
  end

  test "a clean run does not report itself as degraded (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    CurrentScope::SodPreflight.findings

    refute CurrentScope::SodPreflight.degraded?
  end

  # A bug in THIS module must not be reported as a host misconfiguration. The
  # two helpers absorb host failures; anything reaching the top-level rescue as
  # a NoMethodError came from us, and GrantDiagnosis sets the precedent of
  # re-raising exactly that.
  test "a NoMethodError from our own code re-raises instead of degrading (#133)" do
    CurrentScope.config.sod_actions = %w[show]

    # A catalog that cannot answer `grouped` stands in for any slip inside this
    # module's own walk. Host code never reaches this rescue — the helpers own
    # it — so degrading here would report our bug as the host's.
    singleton = CurrentScope.singleton_class
    original = CurrentScope.method(:catalog)
    singleton.define_method(:catalog) { Object.new }

    assert_raises(NoMethodError) { CurrentScope::SodPreflight.findings }
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
