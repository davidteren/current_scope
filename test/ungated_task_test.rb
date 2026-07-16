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

    assert_match(/no provably-ungated controllers/i, output)
    assert_match "current_scope_check!", output,
                 "empty means every routed controller's gate callback was found — say so"
    assert_match "config.gating_tripwire = :warn", output,
                 "an empty list is still not an all-clear: the conditional-skip caveat stays"
  ensure
    singleton.define_method(:catalog, original)
  end
end
