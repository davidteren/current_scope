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

  def sod_blind_spot(subject, permission, count: 1)
    count.times do
      CurrentScope::Event.create!(
        event: "access.sod_blind_spot", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
        target: subject.to_gid.to_s, target_label: subject.name,
        details: { "permission" => permission, "reason" => "no_grant", "blind_spot" => true }
      )
    end
  end

  def run_task
    Rake::Task["current_scope:report"].reenable
    capture_io { Rake::Task["current_scope:report"].invoke }.first
  end

  # #116 — the rollout loop had no exit condition. The ledger is append-only, so
  # a would_deny row survives the grant that fixes it, and the guide told
  # operators to grant until the list empties. Re-checking each recorded denial
  # against live grants is the signal that CAN reach zero.
  test "a denial that has since been granted stops counting as outstanding" do
    alice = User.create!(name: "Alice")
    would_deny(alice, "reports#index", count: 4)

    before = run_task
    assert_match(/STILL ungranted/, before)
    assert_match(/4\s+would-be denials STILL ungranted/, before,
                 "counted in denials, the same unit the detail section totals")

    role = CurrentScope::Role.create!(name: "Reader")
    role.permission_keys = [ "reports#index" ]
    role.save!
    CurrentScope::RoleAssignment.create!(subject: alice, role: role)

    after = run_task

    assert_match(/Every would-be denial recorded so far is now granted/, after,
                 "the grant must clear the outstanding list even though the rows remain")
    assert_match(/append-only/, after)
    assert_no_match(/would-be denials STILL ungranted/, after)
    assert_no_match(/reports#index/, after,
                    "a resolved denial must leave the detail list too, not just the count")
  end

  test "a denial whose subject no longer resolves counts as outstanding, not ready" do
    ghost = User.create!(name: "Ghost")
    would_deny(ghost, "reports#index")
    ghost.delete

    output = run_task

    assert_match(/could not be re-checked/, output)
    assert_match(/cannot tell is/, output)
    assert_no_match(/Every would-be denial recorded so far is now granted/, output,
                    "an unresolvable subject must never read as a finished rollout")
  end

  test "an unre-checkable denial suppresses the all-clear even when the rest are granted" do
    alice = User.create!(name: "Alice")
    ghost = User.create!(name: "Ghost")
    would_deny(alice, "reports#index")
    would_deny(ghost, "reports#index")
    role = CurrentScope::Role.create!(name: "Reader")
    role.permission_keys = [ "reports#index" ]
    role.save!
    CurrentScope::RoleAssignment.create!(subject: alice, role: role)
    ghost.delete

    output = run_task

    assert_match(/could not be re-checked/, output)
    assert_no_match(/this is what empty looks like/, output,
                    "an un-re-checkable denial must never render as a finished rollout")
  end

  # #116 — Guard writes `target: target || subject`, so a record-less denial
  # carries the subject's own GID. Re-asking with the subject as the record is a
  # different question and would keep a granted denial outstanding forever.
  test "a record-less denial re-checks with no record, so granting clears it" do
    alice = User.create!(name: "Alice")
    # This is the shape Guard writes for a record-less action: target == subject.
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name,
      details: { "permission" => "reports#index", "reason" => "no_grant" }
    )
    # Assert the QUESTION, not a downstream answer: whether the difference is
    # visible in the verdict depends on which resolver arm the host's grants
    # happen to hit, and the defect is that the wrong question is asked at all.
    asked = []
    resolver = CurrentScope.resolver
    original = resolver.method(:allow?)
    resolver.define_singleton_method(:allow?) do |**kwargs|
      asked << kwargs
      original.call(**kwargs)
    end

    run_task

    assert_equal 1, asked.size, "one re-check for the one recorded pair"
    assert_nil asked.first[:record],
               "a record-less denial must re-check with record: nil, never with the subject"
  ensure
    resolver&.singleton_class&.remove_method(:allow?)
  end

  # #116 — a denial ON THE SUBJECT'S OWN RECORD stores a target equal to the
  # subject GID, exactly like a record-less one. Guessing from the GIDs would
  # re-check it on the more permissive record-less arm and could report it
  # resolved while it is still denied, which is a false all-clear.
  test "a self-targeted denial re-checks WITH the record, not as record-less" do
    alice = User.create!(name: "Alice")
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name,
      details: { "permission" => "users#update", "reason" => "no_grant", "record_less" => false }
    )

    asked = []
    resolver = CurrentScope.resolver
    original = resolver.method(:allow?)
    resolver.define_singleton_method(:allow?) do |**kwargs|
      asked << kwargs
      original.call(**kwargs)
    end

    run_task

    assert_equal 1, asked.size
    assert_equal alice, asked.first[:record],
                 "the gate asked about this record, so the re-check must too"
  ensure
    resolver&.singleton_class&.remove_method(:allow?)
  end

  # #116 — a legacy row (no record_less flag) and a new one can share a subject,
  # permission and target. Reading the flag off one member of that group would
  # apply it to the other, which is a false all-clear in one direction.
  test "legacy and flagged rows for the same key are re-checked separately" do
    alice = User.create!(name: "Alice")
    base = {
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name
    }
    # Written before the flag existed: ambiguous, falls back to the GID guess.
    CurrentScope::Event.create!(**base, details: { "permission" => "users#update", "reason" => "no_grant" })
    # Written after: explicitly ON the subject's own record.
    CurrentScope::Event.create!(**base, details: { "permission" => "users#update", "reason" => "no_grant", "record_less" => false })

    asked = []
    resolver = CurrentScope.resolver
    original = resolver.method(:allow?)
    resolver.define_singleton_method(:allow?) do |**kwargs|
      asked << kwargs
      original.call(**kwargs)
    end

    run_task

    assert_equal 2, asked.size, "the two rows must not be collapsed into one re-check"
    assert_equal [ nil, alice ], asked.map { |kwargs| kwargs[:record] },
                 "the legacy row falls back; the flagged row keeps its record"
  ensure
    resolver&.singleton_class&.remove_method(:allow?)
  end

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

  # The suffix the README advertises. It's a GlobalID + RoleAssignment lookup —
  # the kind of seam that breaks quietly when an association moves — and it
  # carries real meaning: someone who already holds a role that simply doesn't
  # tick these keys is a different fix from someone with no role at all.
  # (#59 review, cubic)
  test "names the subject's current org role — a held role that doesn't tick these keys reads differently" do
    CurrentScope::RoleAssignment.create!(subject: @alice, role: CurrentScope::Role.create!(name: "Member"))
    would_deny(@alice, "reports#index")
    would_deny(@bob, "reports#index")

    output = run_task

    assert_match(/Alice — currently Member/, output)
    assert_match(/^\s+Bob\s*$/, output, "a subject with no org role gets no suffix, not a dangling dash")
  end

  test "a subject whose record is gone still reports its denials" do
    would_deny(@alice, "reports#index")
    @alice.destroy   # the GID no longer resolves

    output = run_task

    # Best-effort by design: one unresolvable subject must not abort the summary
    # for everyone else, and the rows are still the evidence they always were.
    assert_match "reports#index", output
  end

  test "ignores ledger events that are not would-be denials" do
    would_deny(@alice, "reports#index")
    CurrentScope::Current.actor = @bob
    CurrentScope::Event.record!(event: "role.created", target: CurrentScope::Role.create!(name: "Temp"))

    output = run_task

    assert_match "reports#index", output
    assert_no_match(/role\.created/, output)
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

  # #73: blind-spot 403s are not grantable — list them separately so the survey
  # does not bury the mis-declared SoD hook under would_deny.
  test "lists SoD blind-spot denials separately from grantable would_deny rows" do
    would_deny(@alice, "reports#index", count: 2)
    sod_blind_spot(@bob, "sod_nil#approve", count: 3)

    output = run_task

    assert_match "Would-be denials", output
    assert_match(/2x\s+reports#index/, output)
    assert_match "SoD blind-spot denials", output
    assert_match(/3x\s+sod_nil#approve/, output)
    assert_match "NOT fixed by granting", output
    assert_match "current_scope_record", output
  end

  test "blind-spot only ledger still surfaces the section without would_deny" do
    sod_blind_spot(@alice, "sod_nil#approve")

    output = run_task

    assert_no_match(/Would-be denials/, output)
    assert_match "SoD blind-spot denials", output
    assert_match "sod_nil#approve", output
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

  # --- #134: the static sections. These are NOT ledger-driven. ---

  def role_with(*keys, full_access: false)
    r = CurrentScope::Role.create!(name: "R-#{rand(10**9)}", full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def scope_grant(subject, role, resource)
    CurrentScope::ScopedRoleAssignment.create!(subject: subject, role: role, resource: resource)
  end

  test "a grant that can never match is reported with ZERO ledger rows" do
    # The pin for the four-way empty guard. The ledger is deliberately empty:
    # a grant that cannot match is most likely to exist BEFORE report mode was
    # ever exercised, and the old two-way guard printed "No would-be denials
    # recorded" and stopped — hiding this section in exactly that case.
    report = Report.create!(title: "Q3", requested_by: @bob)
    scope_grant(@alice, role_with, report)

    out = run_task

    assert_match(/can never match/, out)
    assert_match(/role ticks no permissions/, out)
    assert_match(/No would-be denials recorded/, out,
                 "the ledger IS empty and the operator must still be told why — " \
                 "the static section is additional to that explanation, not a " \
                 "replacement for it")
  end

  test "the advisory section names its own false alarm rather than asserting a verdict" do
    # Folder, not Project: a Report-keyed role on a Project is a WORKING
    # parent-chain grant since #108 and must not be flagged.
    folder = Folder.create!(name: "F")
    scope_grant(@alice, role_with("reports#approve"), folder)

    out = run_task

    assert_match(/Worth checking/, out)
    assert_match(/NOT a verdict/, out)
    assert_match(/false alarm/, out,
                 "an operator must not remove a working grant on this section's say-so")
  end

  test "a healthy scoped grant produces neither section" do
    report = Report.create!(title: "Q3", requested_by: @bob)
    scope_grant(@alice, role_with("reports#approve"), report)

    out = run_task

    refute_match(/can never match/, out)
    refute_match(/Worth checking/, out)
    assert_match(/No would-be denials recorded/, out)
  end

  # The task's whole reason for being run is "can I flip to :enforce yet?", and
  # six independently-gated sections made the reader answer that by hand. The
  # summary must lead — and must NOT claim a clearance it cannot prove.
  test "the report leads with a count summary, and refuses to call it a clearance (#133)" do
    would_deny(@alice, "reports#index", count: 2)
    sod_blind_spot(@bob, "sod_nil#approve")

    out = run_task

    assert_operator out.index("CurrentScope report"), :<, out.index("Would-be denials"),
                    "the answer goes before the detail, not after six sections of it"
    assert_match(/2\s+would-be denials/, out)
    assert_match(/1\s+SoD blind-spot denials/, out)
    assert_match(/survey, not a clearance/, out,
                 "neither the ledger nor the preflight can prove it is safe to enforce; " \
                 "claiming so would be the vacuous all-clear this repo keeps refusing")
  end

  test "the summary counts nothing when there is nothing (#133)" do
    out = run_task

    assert_match(/nothing found in any category/, out)
  end

  # --- #133: the SoD-initiator sections, one static and one ledger-driven ---

  def sod_initiator_missing(subject, permission, model, count: 1)
    count.times do
      CurrentScope::Event.create!(
        event: "access.sod_initiator_missing", subject: subject.to_gid.to_s,
        actor: subject.to_gid.to_s, target: subject.to_gid.to_s, target_label: subject.name,
        details: { "permission" => permission, "model" => model }
      )
    end
  end

  test "the static preflight section appears with ZERO ledger rows (#133)" do
    # Same reasoning as the grant sections above: an SoD action with no
    # initiator behind it exists BEFORE report mode is ever exercised, which is
    # exactly when the ledger is empty. sod_actions = %w[show] is the one config
    # the dummy expresses both sides of — DocumentsController declares
    # current_scope_model = Document (no initiator), ReportsController declares
    # Report (has one).
    CurrentScope.config.sod_actions = %w[show]
    CurrentScope.reset_catalog!

    out = run_task

    assert_match(/will RAISE/, out)
    assert_match "documents#show", out
    assert_match "Document defines no current_scope_initiator", out
    refute_match(/reports#show/, out, "Report defines the hook — flagging it would be a false alarm")
    assert_match(/PARTIAL/, out, "an advisory that reads as a verdict gets trusted for what it cannot prove")
    assert_match(/No would-be denials recorded/, out)
  ensure
    CurrentScope.config.sod_actions = []
    CurrentScope.reset_catalog!
  end

  test "no SoD config means no preflight section at all (#133)" do
    CurrentScope.config.sod_actions = []

    out = run_task

    refute_match(/will RAISE/, out)
    refute_match(/preflight/i, out, "a host who never opted into SoD gets no SoD noise")
  end

  # An empty preflight must not read like "the task didn't run". Suppressing the
  # whole section made a clean run and a BROKEN run identical on stdout, and hid
  # the PARTIAL caveat that stops this being taken as a verdict. Same rule the
  # ungated task follows: a vacuous all-clear is worse than a blank.
  test "an empty preflight still says so, with its caveat, when SoD is on (#133)" do
    CurrentScope.config.sod_actions = %w[approve] # no dummy controller declares a model for it
    CurrentScope.reset_catalog!

    out = run_task

    assert_match(/inspected 1 of \d+ routed SoD action/, out,
                 "an empty list means nothing without the coverage behind it: four of the five " \
                 "controllers routing `approve` declare no model, so they were never read")
    assert_match(/PARTIAL/, out, "the caveat must not be trapped inside the non-empty branch")
    refute_match(/COULD NOT COMPLETE/, out, "nothing FAILED here — it just had nothing to read")
  ensure
    CurrentScope.config.sod_actions = []
    CurrentScope.reset_catalog!
  end

  test "a preflight that could not complete says THAT, not 'nothing found' (#133)" do
    CurrentScope.config.sod_actions = %w[show]
    CurrentScope.reset_catalog!
    # Every model check fails, so the run finds nothing AND knows it is blind.
    Document.define_singleton_method(:new) { |*| raise "no connection" }
    Report.define_singleton_method(:new) { |*| raise "no connection" }

    out = run_task

    assert_match(/COULD NOT COMPLETE/, out)
    assert_match(/Do NOT read the absence of findings below as an all-clear/, out)
    refute_match(/no routed SoD action named a model missing/, out,
                 "a blind run must never render as a clean one")
  ensure
    Document.singleton_class.send(:remove_method, :new)
    Report.singleton_class.send(:remove_method, :new)
    CurrentScope.config.sod_actions = []
    CurrentScope.reset_catalog!
  end

  test "raised requests get their own section, apart from denials (#133)" do
    would_deny(@alice, "reports#index", count: 2)
    sod_initiator_missing(@bob, "documents#show", "Invoice", count: 3)

    out = run_task

    assert_match "Would-be denials", out
    assert_match(/2x\s+reports#index/, out)
    assert_match(/RAISED \(500s\) — NOT fixed by granting/, out,
                 "its three sibling sections put non-fixability in the header; a reader " \
                 "scanning headers must not have to read the Total line to learn it here")
    assert_match(/3x\s+documents#show — Invoice/, out)
    assert_match "NOT denials and granting changes nothing", out,
                 "an operator reading this next to would_deny must not try to grant their way out"
  end

  test "a raised-request ledger alone still surfaces its section (#133)" do
    sod_initiator_missing(@alice, "documents#show", "Invoice")

    out = run_task

    refute_match(/Would-be denials/, out)
    assert_match(/RAISED \(500s\) — NOT fixed by granting/, out)
    assert_match "documents#show", out
  end
end
