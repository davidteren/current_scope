require "test_helper"
require "rake"

# U4/R8 of plan 019: `current_scope:report` turns recorded would-be denials into
# a starter role grid. Report mode collects the data; without this the host is
# left hand-writing GROUP BYs over a JSON column, which is the manual step the
# mode was supposed to remove.
class ReportTaskTest < ActiveSupport::TestCase
  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")

    CurrentScope::Event.delete_all
    Rake::Task.clear
    Rake::TaskManager.record_task_metadata = true
    load Rails.root.join("../../lib/tasks/current_scope_tasks.rake").expand_path
    Rake::Task.define_task(:environment)
  end

  teardown { Rake::Task.clear }

  def would_deny(subject, permission, count: 1)
    count.times do
      CurrentScope::Event.create!(
        event: "access.would_deny", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
        target: subject.to_gid.to_s, target_label: subject.name,
        details: { "permission" => permission, "reason" => "no_grant" }
      )
    end
  end

  def run_task = capture_io { Rake::Task["current_scope:report"].invoke }.first

  test "counts each subject's would-be denials, most-denied first" do
    would_deny(@alice, "reports#index", count: 5)
    would_deny(@alice, "reports#show", count: 2)
    would_deny(@bob, "reports#approve", count: 1)

    output = run_task

    assert_match "reports#approve", output
    assert_match(/5x\s+reports#index/, output)
    assert_match(/2x\s+reports#show/, output)

    # Sorted by count desc: the grid should read as "grant this first".
    assert_operator output.index("reports#index"), :<, output.index("reports#show"),
                    "the most-denied key is the most useful one to grant, so it goes first"
  end

  test "groups by subject — the axis a role grid is built on" do
    would_deny(@alice, "reports#index")
    would_deny(@bob, "reports#approve")

    output = run_task

    assert_match "Alice", output
    assert_match "Bob", output
  end

  test "ignores ledger events that are not would-be denials" do
    would_deny(@alice, "reports#index")
    CurrentScope::Current.actor = @bob
    CurrentScope::Event.record!(event: "role.created", target: CurrentScope::Role.create!(name: "Temp"))

    output = run_task

    assert_match "reports#index", output
    assert_no_match(/role.created/, output)
  end

  # The empty case is the one a host actually hits first, and "no output" is
  # indistinguishable from "the task is broken". It has to say why it might be
  # empty — report mode off and audit off are both silent, and both look like this.
  test "an empty ledger explains itself instead of printing nothing" do
    output = run_task

    assert_match(/no would-be denials/i, output)
    assert_match "enforcement", output, "the likeliest cause is report mode never being on"
    assert_match "audit", output, "the other likely cause is the ledger being off"
  end

  # A host that turned report mode on without running the migration gets nothing
  # recorded (the ledger degrades + warns). Reaching for the summary is exactly
  # how they'd find out — so it must name the fix, not raise a stack trace.
  #
  # ponytail: plain singleton swap — minitest 6 dropped minitest/mock. `abort`
  # raises SystemExit (the existing current_scope:grant pattern — a non-zero exit
  # is right for a CLI), so the message lands on stderr and the exit is expected.
  test "a missing events table gives the same guidance the ledger does, not a stack trace" do
    singleton = CurrentScope::Event.singleton_class
    original = CurrentScope::Event.method(:where)
    singleton.define_method(:where) { |*| raise ActiveRecord::StatementInvalid, "no such table: current_scope_events" }

    error = assert_raises(SystemExit) { capture_io { Rake::Task["current_scope:report"].invoke } }

    assert_match(/migrat/i, error.message, "the fix is to run the migration — say so")
    assert_match "current_scope_events", error.message
  ensure
    singleton.define_method(:where, original)
  end

  test "an unrelated database error is not swallowed as a missing table" do
    singleton = CurrentScope::Event.singleton_class
    original = CurrentScope::Event.method(:where)
    singleton.define_method(:where) { |*| raise ActiveRecord::StatementInvalid, "connection refused" }

    # Rescuing broadly here would tell a host to run migrations for a problem that
    # has nothing to do with migrations.
    #
    # SystemExit is named alongside the real expectation deliberately. `abort`
    # raises it, it is NOT a StandardError, so an assert_raises that doesn't name
    # it lets it escape — killing the minitest process mid-run, which reports
    # EXIT 0. This exact test silently "passed" that way until a mutation run
    # showed the suite truncating instead of failing. Catching it here turns that
    # into an honest failure.
    error = assert_raises(ActiveRecord::StatementInvalid, SystemExit) do
      capture_io { Rake::Task["current_scope:report"].invoke }
    end

    assert_kind_of ActiveRecord::StatementInvalid, error,
                   "a connection error is not a missing table — telling this host to run migrations " \
                   "sends them after the wrong problem"
  ensure
    singleton.define_method(:where, original)
  end
end
