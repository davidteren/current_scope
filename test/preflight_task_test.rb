require "test_helper"
require "rake"

# current_scope:preflight prints one headline. It is not a clearance to set :enforce.
class PreflightTaskTest < ActiveSupport::TestCase
  NOT_READY = "CurrentScope preflight: NOT READY. A check found a problem."
  CANNOT_TELL = "CurrentScope preflight: CANNOT TELL. A required check could not run."
  NOTHING = "CurrentScope preflight: nothing to act on in the checks that ran."

  setup do
    CurrentScope::Event.delete_all
    @originals = {
      enforcement: CurrentScope.config.enforcement,
      audit: CurrentScope.config.audit,
      sod: CurrentScope.config.sod_actions
    }
    Rake::Task.clear
    Rake::TaskManager.record_task_metadata = true
    load Rails.root.join("../../lib/tasks/current_scope_tasks.rake").expand_path
    Rake::Task.define_task(:environment)
  end

  teardown do
    CurrentScope.config.enforcement = @originals[:enforcement]
    CurrentScope.config.audit = @originals[:audit]
    CurrentScope.config.sod_actions = @originals[:sod]
    CurrentScope.reset_catalog!
    Rake::Task.clear
  end

  test "a found problem prints the NOT READY headline and no clearance" do
    CurrentScope.config.enforcement = :report
    CurrentScope.catalog.define_singleton_method(:grouped) { { "bare" => [ "show" ] } }

    output = run_task

    assert_equal 1, output.scan(NOT_READY).size
    refute_includes output, CANNOT_TELL
    refute_includes output, NOTHING
    assert_task_shape(output)
    refute_clearance(output)
  end

  test "enforce mode with nothing else to act on prints the CANNOT TELL headline" do
    CurrentScope.config.enforcement = :enforce
    CurrentScope.config.audit = true
    CurrentScope.catalog.define_singleton_method(:grouped) { { "reports" => [ "index" ] } }

    output = run_task

    assert_equal 1, output.scan(CANNOT_TELL).size
    refute_includes output, NOT_READY
    refute_includes output, NOTHING
    assert_match(/Enforcement is :enforce/, output)
    assert_task_shape(output)
    refute_clearance(output)
  end

  test "a clean report-mode survey prints the nothing-to-act-on headline" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = true
    CurrentScope.catalog.define_singleton_method(:grouped) { { "reports" => [ "index" ] } }

    output = run_task

    assert_equal 1, output.scan(NOTHING).size
    refute_includes output, NOT_READY
    refute_includes output, CANNOT_TELL
    assert_match(/authentication/i, output)
    assert_match(/skip_before_action only:\/except:/, output)
    assert_task_shape(output)
    refute_clearance(output)
  end

  # AE1. One still-denied row, report mode, SoD quiet, no ungated controller.
  test "AE1 a still-denied row is NOT READY and the unchecked list is still printed" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = true
    CurrentScope.catalog.define_singleton_method(:grouped) { { "reports" => [ "index" ] } }
    alice = User.create!(name: "Alice")
    would_deny(alice, "reports#index")
    before = CurrentScope::Event.count

    output = run_task

    assert_equal NOT_READY, output.lines.first.chomp
    assert_match(/would-be denials STILL ungranted/, output)
    assert_includes output, "Not checked:"
    assert_match(/authentication/i, output)
    assert_equal before, CurrentScope::Event.count
    refute_clearance(output)
  end

  # AE2. Enforce mode, empty ledger, every other check clean.
  test "AE2 an empty ledger outside report mode is CANNOT TELL" do
    CurrentScope.config.enforcement = :enforce
    CurrentScope.config.audit = true
    CurrentScope.catalog.define_singleton_method(:grouped) { { "reports" => [ "index" ] } }
    assert_equal 0, CurrentScope::Event.where(event: "access.would_deny").count

    output = run_task

    assert_equal CANNOT_TELL, output.lines.first.chomp
    assert_match(/Enforcement is :enforce/, output)
    assert_includes output, "Not checked:"
    assert_equal 0, CurrentScope::Event.count
  end

  # AE3. No act-on counts, and the SoD preflight skipped a controller.
  test "AE3 a degraded SoD preflight with nothing to act on is CANNOT TELL" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = true
    CurrentScope.catalog.define_singleton_method(:grouped) { { "reports" => [ "show" ] } }
    singleton = CurrentScope::SodPreflight.singleton_class
    original = CurrentScope::SodPreflight.method(:declared_model_for)
    singleton.define_method(:declared_model_for) do |path, _reflection, skipped|
      skipped << [ path, RuntimeError.new("skipped") ]
      nil
    end
    CurrentScope.config.sod_actions = %w[show]

    output = run_task

    assert_equal CANNOT_TELL, output.lines.first.chomp
    assert_match(/could not complete/, output)
    refute_match(/would-be denials STILL ungranted/, output)
  ensure
    singleton.define_method(:declared_model_for, original)
    singleton.send(:private, :declared_model_for)
  end

  # A problem outranks a check that could not run. Reversing that prints CANNOT TELL.
  test "a denial outranks a degraded SoD preflight" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = true
    CurrentScope.catalog.define_singleton_method(:grouped) { { "reports" => [ "show" ] } }
    alice = User.create!(name: "Alice")
    would_deny(alice, "reports#index")
    singleton = CurrentScope::SodPreflight.singleton_class
    original = CurrentScope::SodPreflight.method(:declared_model_for)
    singleton.define_method(:declared_model_for) do |path, _reflection, skipped|
      skipped << [ path, RuntimeError.new("skipped") ]
      nil
    end
    CurrentScope.config.sod_actions = %w[show]

    output = run_task

    assert_equal NOT_READY, output.lines.first.chomp
    assert_match(/could not complete/, output)
  ensure
    singleton.define_method(:declared_model_for, original)
    singleton.send(:private, :declared_model_for)
  end

  # AE4. Clean checks, plus a moot row that must not change the headline.
  test "AE4 nothing to act on still names the unchecked list and a moot count" do
    CurrentScope.config.enforcement = :report
    CurrentScope.config.audit = true
    CurrentScope.catalog.define_singleton_method(:grouped) { { "reports" => [ "index" ] } }
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Gone", requested_by: alice)
    would_deny_on(alice, "reports#show", report.to_gid.to_s)
    report.delete

    output = run_task

    assert_equal NOTHING, output.lines.first.chomp
    assert_match(/authentication/i, output)
    assert_match(/skip_before_action only:\/except:/, output)
    refute_clearance(output)
    lines = output.lines.map(&:chomp)
    between = lines[(lines.index("Act on:") + 1)...lines.index("Not checked:")]
    assert_includes between, "  None."
    moot = between.grep(/not work to grant/)
    assert_equal 1, moot.size
    assert_match(/\b1\b/, moot.first)
    refute moot.first.start_with?("  "), "the moot count is not an Act on row"
  end

  private

  def would_deny(subject, permission)
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
      target: subject.to_gid.to_s, target_label: subject.name,
      details: { "permission" => permission, "reason" => "no_grant" }
    )
  end

  def would_deny_on(subject, permission, target_gid)
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
      target: target_gid, target_label: "a target",
      details: { "permission" => permission, "reason" => "no_grant", "record_less" => false }
    )
  end

  def run_task
    Rake::Task["current_scope:preflight"].reenable
    capture_io { Rake::Task["current_scope:preflight"].invoke }.first
  end

  def assert_task_shape(output)
    assert_operator output.index("Why:"), :<, output.index("Act on:")
    assert_operator output.index("Act on:"), :<, output.index("Not checked:")
    assert_match("bin/rails current_scope:report", output)
  end

  def refute_clearance(output)
    refute_match(/safe to enforce/, output)
    refute_match(/ready to flip/i, output)
    refute_match(/host is ready/i, output)
  end
end
