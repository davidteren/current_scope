require "test_helper"
require "rake"

# U7: `current_scope:ungated` is the static half of the ungated-surface
# inventory — a retrofitting host asks "what is ungated?" from the terminal,
# with no mixin, no deploy, no traffic. It walks the route-derived catalog
# through GatingReflection, so it lists only what the callback chain PROVES
# (absence); the conditional-skip residual belongs to the runtime tripwire.
class UngatedTaskTest < ActiveSupport::TestCase
  setup do
    Rake::Task.clear
    Rake::TaskManager.record_task_metadata = true
    load Rails.root.join("../../lib/tasks/current_scope_tasks.rake").expand_path
    Rake::Task.define_task(:environment)
  end

  teardown { Rake::Task.clear }

  def run_task = capture_io { Rake::Task["current_scope:ungated"].invoke }.first

  test "lists the provably-ungated controllers with their routed actions, and omits gated ones" do
    output = run_task

    # The whole ungated family, including the #62 fail-open: a child that
    # silently inherits its base's bare skip is provably ungated too.
    %w[bare identity inherited_skip_base inherited_skip_child tripwire_ungated writes].each do |controller|
      assert_match(/^  #{controller} /, output)
    end
    assert_match "guarded, unguarded", output, "a marked controller carries its routed actions"

    # Gated controllers stay out — including the namespaced admin/reports.
    # No listed controller's name contains "reports", so one no-match pins
    # reports, admin/reports, slug/external_id/nested_reports at once.
    assert_no_match(/reports/, output)
  end

  test "a child that re-asserts the gate does not appear — the guide's mitigation works" do
    assert_no_match(/reasserted_gate/, run_task)
  end

  test "a conditional skip does not appear, and the output names :warn as the way to catch it" do
    output = run_task

    # Both conditional-skip twins (with and without the tripwire mixin): the
    # callback is PRESENT wearing a condition, which is unprovable by
    # reflection (KTD-3) — never listed, even though #index really runs open.
    assert_no_match(/conditional_skip/, output)

    # The residual is stated at the point of use: the list must name its own
    # limit and point at the runtime half.
    assert_match "skip_before_action", output
    assert_match "config.gating_tripwire = :warn", output
  end

  test "the injected break-glass key is stripped from the listing and named as live" do
    # allow_sod_bypass + an SoD action routed on the ungated writes controller
    # makes the catalog inject writes#bypass_sod. That grant is LIVE even on an
    # ungated controller (the grid's KTD-9 exemption) — printing it under
    # "grants nothing" would call the most sensitive grant in the grid inert.
    original_bypass = CurrentScope.config.allow_sod_bypass
    original_sod = CurrentScope.config.sod_actions
    CurrentScope.config.allow_sod_bypass = true
    CurrentScope.config.sod_actions = %w[guarded]
    CurrentScope.reset_catalog!

    output = run_task

    assert_match(/^  writes \(guarded, unguarded\)$/, output,
                 "the bypass key must not appear among writes' routed actions")
    assert_no_match(/^  writes \(.*bypass_sod.*\)/, output)
    assert_match(/bypass_sod omitted .* break-glass stays LIVE/i, output,
                 "the omission is stated, not silent")
  ensure
    CurrentScope.config.allow_sod_bypass = original_bypass
    CurrentScope.config.sod_actions = original_sod
    CurrentScope.reset_catalog!
  end

  test "a real routed action sharing the bypass name is audited, not stripped" do
    # sod_bypass_permission is set to "unguarded" — a REAL routed action on the
    # ungated writes controller. Only the catalog-INJECTED key may be stripped
    # from the listing; omitting a real fail-open route because of a name
    # collision would hide exactly what the audit exists to find. (#79 review)
    original_bypass = CurrentScope.config.allow_sod_bypass
    original_sod = CurrentScope.config.sod_actions
    original_perm = CurrentScope.config.sod_bypass_permission
    CurrentScope.config.allow_sod_bypass = true
    CurrentScope.config.sod_actions = %w[guarded]
    CurrentScope.config.sod_bypass_permission = "unguarded"
    CurrentScope.reset_catalog!

    output = run_task

    assert_match(/^  writes \(guarded, unguarded\)$/, output,
                 "the routed action stays in the audit despite sharing the bypass name")
    assert_no_match(/omitted from the listing/, output)
  ensure
    CurrentScope.config.allow_sod_bypass = original_bypass
    CurrentScope.config.sod_actions = original_sod
    CurrentScope.config.sod_bypass_permission = original_perm
    CurrentScope.reset_catalog!
  end

  test "a malformed bypass permission raises the catalog's loud error, never a silent mis-parse" do
    # sod_actions stays [] so the catalog's own derive never validates the
    # permission — the exact corner where a loose split("#").last would turn
    # "reports#" into a believable wrong action name. The task delegates to
    # the catalog's parse, so the misconfiguration raises with the fix named.
    original_bypass = CurrentScope.config.allow_sod_bypass
    original_perm = CurrentScope.config.sod_bypass_permission
    CurrentScope.config.allow_sod_bypass = true
    CurrentScope.config.sod_bypass_permission = "reports#"
    CurrentScope.reset_catalog!

    error = assert_raises(CurrentScope::ConfigurationError) { run_task }
    assert_match "not a bare action or a single controller#action", error.message
  ensure
    CurrentScope.config.allow_sod_bypass = original_bypass
    CurrentScope.config.sod_bypass_permission = original_perm
    CurrentScope.reset_catalog!
  end

  test "an empty CATALOG names that nothing was inspected — never a vacuous all-clear" do
    singleton = CurrentScope.singleton_class
    original = CurrentScope.method(:catalog)
    stub = Object.new
    def stub.grouped = {}
    singleton.define_method(:catalog) { stub }

    output = run_task

    assert_match(/nothing was\s+inspected/i, output)
    assert_match "config.excluded_controllers", output
    assert_no_match(/every routed controller has/, output,
                    "an empty set must not be described as all-inspected")
  ensure
    singleton.define_method(:catalog, original)
  end

  test "an empty inventory names its cause instead of printing a bare all-clear" do
    # The dummy routes provably-ungated controllers on purpose, so empty is
    # produced by narrowing the catalog to a gated controller (the report-task
    # tests swap singleton methods the same way).
    singleton = CurrentScope.singleton_class
    original = CurrentScope.method(:catalog)
    stub = Object.new
    def stub.grouped = { "reports" => [ "index" ] }
    singleton.define_method(:catalog) { stub }

    output = run_task

    assert_match(/no controller was proven ungated/i, output)
    assert_match "unclassified", output,
                 "an unresolvable controller was not inspected — the blank must not vouch for it"
    assert_match "config.gating_tripwire = :warn", output,
                 "an empty list is still not an all-clear: the conditional-skip caveat stays"
  ensure
    singleton.define_method(:catalog, original)
  end
end
