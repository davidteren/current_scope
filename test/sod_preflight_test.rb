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
  test "a current_scope_model hook that raises degrades to silence" do
    CurrentScope.config.sod_actions = %w[index]

    DocumentsController.define_singleton_method(:new) { |*| raise "the host's own hook blew up" }

    assert_empty CurrentScope::SodPreflight.findings.select { |p, _| p.start_with?("documents#") }
  ensure
    # Removing the override restores the inherited Class#new — no saved method
    # to put back, and nothing left behind for the next test in this process.
    DocumentsController.singleton_class.send(:remove_method, :new)
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
    CurrentScope.config.sod_actions = %w[show]
    CurrentScope.reset_catalog!

    Rails.application.reloader.prepare!

    refute CurrentScope.catalog.instance_variable_defined?(:@keys),
           "a to_prepare block derived the permission catalog. If routes are not " \
           "drawn yet at that point, the empty derivation is MEMOIZED and every " \
           "gated request raises for the rest of the process. Move the read to " \
           "after_routes_loaded."
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
