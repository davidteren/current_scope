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

  # #190 — the existing would_deny helper always writes the SUBJECT's own GID as
  # the target, which is the record-less shape. These arms need a denial that
  # names a real, separate record, so the re-check takes the target branch.
  def would_deny_on(subject, permission, target_gid, count: 1)
    count.times do
      CurrentScope::Event.create!(
        event: "access.would_deny", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
        target: target_gid, target_label: "a target",
        details: { "permission" => permission, "reason" => "no_grant", "record_less" => false }
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

  # #190 — a denial whose target RECORD was deleted can never recur, because the
  # gate is never asked about a row that is gone. Counting it as outstanding held
  # the #116 exit condition open on every host that deletes records. These arms
  # split "the class loaded and the row is gone" (moot) from "we cannot tell"
  # (unknown), which stays counted.

  # CHANGE-DETECTING: red on main at 8036b33, where the deleted target locates to
  # nil, lands in unknown, and is counted.
  test "a denial whose target record was deleted is not counted as outstanding" do
    report = Report.create!(title: "A report", requested_by: @alice)
    gid = report.to_gid.to_s
    would_deny_on(@alice, "reports#show", gid)
    report.delete

    output = run_task

    assert_no_match(/would-be denials STILL ungranted/, output)
    assert_no_match(/Would-be denials still outstanding/, output)
    assert_match(/name a record that no longer loads/, output)
  end

  # PIN: green on main. Stops the fix widening :moot to cover NameError.
  test "a denial whose target CLASS no longer resolves still counts as outstanding" do
    would_deny_on(@alice, "reports#show", "gid://dummy/VanishedModel/1")

    output = run_task

    assert_match(/could not be re-checked/, output)
    assert_match(/would-be denials STILL ungranted/, output)
    assert_no_match(/name a record that no longer loads/, output)
  end

  # PIN, and the ORDERING pin: the only arm that fails if an implementer resolves
  # the target before the subject.
  test "a denial with both a dead subject and a dead target counts as unknown, not moot" do
    ghost = User.create!(name: "Ghost")
    report = Report.create!(title: "A report", requested_by: ghost)
    would_deny_on(ghost, "reports#show", report.to_gid.to_s)
    report.delete
    ghost.delete

    output = run_task

    assert_match(/could not be re-checked/, output)
    assert_match(/would-be denials STILL ungranted/, output)
    assert_no_match(/name a record that no longer loads/, output)
  end

  # PIN: green on main. An unparseable GID is not evidence a record was deleted.
  test "a denial with an unparseable target counts as unknown, not moot" do
    would_deny_on(@alice, "reports#show", "not a gid")

    output = run_task

    assert_match(/could not be re-checked/, output)
    assert_no_match(/name a record that no longer loads/, output)
  end

  # CHANGE-DETECTING: the bake scenario in miniature. One denial granted, one on a
  # record that was deleted. The headline reaches zero, which is the whole point.
  test "granting the last live denial reaches zero when the rest are moot" do
    live = Report.create!(title: "A report", requested_by: @alice)
    gone = Report.create!(title: "A report", requested_by: @alice)
    would_deny_on(@alice, "reports#show", live.to_gid.to_s)
    would_deny_on(@alice, "reports#show", gone.to_gid.to_s)
    gone.delete

    role = CurrentScope::Role.create!(name: "Reader")
    role.permission_keys = [ "reports#show" ]
    role.save!
    CurrentScope::RoleAssignment.create!(subject: @alice, role: role)

    output = run_task

    assert_no_match(/would-be denials STILL ungranted/, output)
    assert_no_match(/Would-be denials still outstanding/, output)
    assert_match(/name a record that no longer loads/, output)
    assert_match(/Nothing recorded so far is still outstanding/, output)
    assert_no_match(/Every would-be denial recorded so far is now granted/, output,
                    "a moot denial was never granted, so the all-clear must not say it was")
  end

  # CHANGE-DETECTING: pins the zero-resolved wording, and KTD-7's decision that
  # "nothing found in any category" is suppressed on a moot-only ledger.
  test "a moot-only ledger reports the moot line and never nothing-found" do
    gone = Report.create!(title: "A report", requested_by: @alice)
    would_deny_on(@alice, "reports#show", gone.to_gid.to_s)
    gone.delete

    output = run_task

    assert_match(/name a record that no longer loads/, output)
    assert_no_match(/nothing found in any category/, output)
    assert_no_match(/0 category\(ies\)/, output,
                    "suppressing the nothing-found line must not fall through to an empty category list")
    assert_match(/^CurrentScope report: nothing to act on in any category\.$/, output,
                 "every run still names itself on the first line; a headless report reads as a broken task")
    assert_match(/Nothing recorded so far is still outstanding/, output)
    assert_match(/0 subject\/permission pair\(s\)/, output,
                 "no denial was granted, so the pair count reads zero rather than being hidden")
  end

  # CHANGE-DETECTING: units. The headline counts DENIALS and must exclude moot.
  test "the headline counts only outstanding denials and the moot line counts denials" do
    live = Report.create!(title: "A report", requested_by: @alice)
    gone = Report.create!(title: "A report", requested_by: @alice)
    would_deny_on(@alice, "reports#show", live.to_gid.to_s, count: 3)
    would_deny_on(@alice, "reports#index", gone.to_gid.to_s, count: 2)
    gone.delete

    output = run_task

    assert_match(/3\s+would-be denials STILL ungranted/, output,
                 "3 outstanding denials, not 5 with the moot ones added, and not 2")
    assert_match(/2 recorded denial\(s\) name a record that no longer loads/, output,
                 "counted in denials, not in pairs")
    assert_match(/reports#show/, output)
    assert_no_match(/reports#index/, output,
                    "a moot denial must leave the act-on-this list, not just the count")
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
    # Compared as a set: the query has no ORDER BY, so which group is re-checked
    # first is unspecified. The property under test is that BOTH questions get
    # asked, not the order they arrive in.
    assert_equal [ nil, alice ].to_set, asked.map { |kwargs| kwargs[:record] }.to_set,
                 "the legacy row falls back; the flagged row keeps its record"
  ensure
    resolver&.singleton_class&.remove_method(:allow?)
  end

  # --- #196: the report must ask the question the GATE asks ---
  #
  # CurrentScope::Guard fills `model:` from the controller's current_scope_model
  # hook on every real request, and the resolver's record-less arm needs it to
  # see a scoped grant at all. Re-asking without it asks a stricter question and
  # calls a subject denied whom the gate admits. On the bake host that was 406
  # of 696 rows, and the fix it implied was to grant a whole controller to
  # everyone.

  def would_deny_with_model(subject, permission, model_name)
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
      target: subject.to_gid.to_s, target_label: subject.name,
      details: { "permission" => permission, "reason" => "no_grant",
                 "record_less" => true, "model" => model_name }
    )
  end

  test "a denial recorded with a model leaves the list once the scoped grant admits the subject" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    scope_grant(alice, role_with("reports#index"), report)
    would_deny_with_model(alice, "reports#index", "Report")

    output = run_task

    assert_match(/nothing to act on|Every would-be denial/, output,
      "the gate admits her through current_scope_model, so the report must agree")
    assert_no_match(/reports#index/, output,
      "a denial the gate would allow must not be listed as still ungranted")
  end

  test "the model does not blanket-allow: no scoped grant is still outstanding" do
    alice = User.create!(name: "Alice")
    Report.create!(title: "Q3", requested_by: alice)
    would_deny_with_model(alice, "reports#index", "Report")

    output = run_task

    assert_match(/would-be denials STILL ungranted/, output,
      "the grant is what opens the arm, not the model")
    assert_match(/reports#index/, output)
  end

  test "the recorded model is the one passed back to the resolver" do
    alice = User.create!(name: "Alice")
    would_deny_with_model(alice, "reports#index", "Report")

    asked = []
    resolver = CurrentScope.resolver
    original = resolver.method(:allow?)
    resolver.define_singleton_method(:allow?) do |**kwargs|
      asked << kwargs
      original.call(**kwargs)
    end

    run_task

    assert_equal 1, asked.size
    assert_equal Report, asked.first[:model],
      "the gate asked with this type, so the re-check must too"
    assert_nil asked.first[:record], "and still record-less"
  ensure
    resolver&.singleton_class&.remove_method(:allow?)
  end

  test "a recorded model that no longer resolves is still asked, and a deny is unknown" do
    alice = User.create!(name: "Alice")
    would_deny_with_model(alice, "reports#index", "LongDeletedThing")

    asked = []
    resolver = CurrentScope.resolver
    original = resolver.method(:allow?)
    resolver.define_singleton_method(:allow?) do |**kwargs|
      asked << kwargs
      original.call(**kwargs)
    end

    output = run_task

    assert_equal 1, asked.size, "ask anyway: an allow without the type is an allow with it"
    assert_nil asked.first[:model], "and ask it the only way left, without one"
    assert_match(/could not be re-checked/, output)
    assert_match(/would-be denials STILL ungranted/, output,
      "the DENY is the answer the missing type could have changed, so it is cannot-tell")
    assert_match(/name a model class that no longer loads/, output,
      "and this row has its own remedy: no grant can clear it, so say so")
  ensure
    resolver&.singleton_class&.remove_method(:allow?)
  end

  # The other half: a dead type name must not strand a subject the gate already
  # allows. `model:` is read only by an allow arm, so an org-wide grant answers
  # this with or without the type, and refusing to ask would leave the row on
  # the grant-these list for ever, under a subject the same report labels as
  # holding the role that clears it.
  test "a dead model name does not strand a subject an org-wide grant already allows" do
    alice = User.create!(name: "Alice")
    role = CurrentScope::Role.create!(name: "Admin", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: alice, role: role)
    would_deny_with_model(alice, "reports#index", "LongDeletedThing")

    output = run_task

    assert_no_match(/would-be denials STILL ungranted/, output,
      "full_access answers this without needing the type at all")
    assert_match(/nothing found in any category|Every would-be denial/, output)
  end

  test "a legacy row with no model is re-checked without one, and the report says so" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    # The grant the gate WOULD have seen through current_scope_model.
    scope_grant(alice, role_with("reports#index"), report)
    # Written before the field existed: no "model" key at all.
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name,
      details: { "permission" => "reports#index", "reason" => "no_grant", "record_less" => true }
    )

    output = run_task

    assert_match(/would-be denials STILL ungranted/, output,
      "without a recorded type the record-less arm cannot fire — today's behaviour, unchanged")
    assert_match(/recorded BEFORE this task stored the/, output,
      "and the report must say which rows it cannot vouch for")
    assert_match(/Do not grant on the strength of THIS line/, output,
      "because the obvious reading of the list is the dangerous one")
    assert_match(/\* = includes denial\(s\) re-checked WITHOUT the gate's model/, output,
      "and the legend belongs beside the list, under a header that says grant these")
  end

  # A legacy row and a row that recorded no model are DIFFERENT: nil is
  # knowledge, absent is not. Collapsing them would apply one row's caveat to
  # the other, in the direction that hides it.
  test "a row recording no model is not counted as a legacy row" do
    alice = User.create!(name: "Alice")
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name,
      details: { "permission" => "reports#index", "reason" => "no_grant",
                 "record_less" => true, "model" => nil }
    )

    output = run_task

    assert_match(/would-be denials STILL ungranted/, output)
    assert_no_match(/recorded BEFORE this task stored the/, output,
      "this row DID record the gate's answer: there was no model")
  end

  # #196 review — the mixed case, and the one that breaks the invariant the
  # detail list is built on. A legacy row and a modern row can share a subject,
  # permission and target and still belong in different buckets: the modern one
  # re-checks WITH the type and is resolved, the legacy one cannot and stays
  # outstanding. If the detail list keys on fewer things than the grouping does,
  # it matches both ledger rows and prints a total the headline disagrees with.
  # The caveat tells the operator to exercise the action again and read the
  # fresh row. The ledger is append-only, so the fresh row is a NEW group and
  # the old one cannot clear itself: without this the advice moves nothing, and
  # the only thing that does is the org-wide grant #196 exists to prevent.
  test "a legacy row is answered by a fresher row that carried the model" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    scope_grant(alice, role_with("reports#index"), report)
    base = {
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name
    }
    CurrentScope::Event.create!(**base, created_at: 2.days.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true
    })
    CurrentScope::Event.create!(**base, created_at: 1.day.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true,
      "model" => "Report"
    })

    output = run_task

    assert_no_match(/would-be denials STILL ungranted/, output,
      "the question was asked again with the type and came back granted")
    assert_match(/predate the stored model and have since been/, output)
    assert_match(/ASKED AGAIN/, output)
  end

  # The OLDEST shape: a row with neither a model key nor a record_less flag.
  # Its record-lessness is inferred from the GIDs, and using the raw flag to
  # decide supersession would leave exactly these rows carrying the caveat with
  # no way to act on it (#196 review).
  test "a row predating the record_less flag is superseded too" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    scope_grant(alice, role_with("reports#index"), report)
    base = {
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name
    }
    # No record_less key AND no model key: the shape this file's own would_deny
    # helper writes, and the oldest thing a ledger can hold.
    CurrentScope::Event.create!(**base, created_at: 2.days.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant"
    })
    CurrentScope::Event.create!(**base, created_at: 1.day.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true,
      "model" => "Report"
    })

    output = run_task

    assert_no_match(/would-be denials STILL ungranted/, output,
      "the same question was asked again with the type and came back granted")
    assert_match(/ASKED AGAIN/, output)
  end

  # "Exercise the action AGAIN" means the answer has to be newer than the row it
  # answers. During a rolling deploy an older new-format row would otherwise
  # hide a later old-format denial, which is a real denial dropped off the list.
  test "an OLDER model-bearing answer does not supersede a newer legacy row" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    scope_grant(alice, role_with("reports#index"), report)
    base = {
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name
    }
    CurrentScope::Event.create!(**base, created_at: 2.days.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true,
      "model" => "Report"
    })
    CurrentScope::Event.create!(**base, created_at: 1.day.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true
    })

    output = run_task

    assert_match(/would-be denials STILL ungranted/, output,
      "the legacy row is the LATER evidence; an older answer cannot speak for it")
    assert_no_match(/ASKED AGAIN/, output)
  end

  # Two rows written in the same request share a created_at, so "newer" is
  # (created_at, id): a strict comparison on the timestamp alone would refuse
  # the answer and leave a stale denial standing (#196 review).
  test "an answer recorded in the same instant still answers the legacy row" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    scope_grant(alice, role_with("reports#index"), report)
    stamp = 1.day.ago
    base = {
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name, created_at: stamp
    }
    CurrentScope::Event.create!(**base, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true
    })
    CurrentScope::Event.create!(**base, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true,
      "model" => "Report"
    })

    output = run_task

    assert_no_match(/would-be denials STILL ungranted/, output,
      "the answer was written after the legacy row, to the row id if not the clock")
    assert_match(/ASKED AGAIN/, output)
  end

  # current_scope_model can return different types for the same permission, and
  # record-less rows all carry the subject as their target, so a granted answer
  # for one type is no answer for another. If any model-bearing sibling is still
  # denied, the legacy row stands.
  test "a still-denied model-bearing sibling blocks supersession" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    scope_grant(alice, role_with("reports#index"), report)
    base = {
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name
    }
    CurrentScope::Event.create!(**base, created_at: 3.days.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true
    })
    CurrentScope::Event.create!(**base, created_at: 2.days.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true,
      "model" => "Report"
    })
    # A second type for the same permission, with no grant behind it.
    CurrentScope::Event.create!(**base, created_at: 1.day.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true,
      "model" => "Document"
    })

    output = run_task

    assert_match(/would-be denials STILL ungranted/, output,
      "one type is still refused, so the row that named no type is not answered")
    assert_no_match(/ASKED AGAIN/, output)
  end

  # And when the fresher row is still DENIED there is nothing to supersede, so
  # both rows stand. This is the case that pins the headline and the detail list
  # on the same key: the grouping has five parts and the list must too.
  test "a legacy row and a still-denied modern row are both counted, once each" do
    alice = User.create!(name: "Alice")
    base = {
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: alice.to_gid.to_s, target_label: alice.name
    }
    CurrentScope::Event.create!(**base, created_at: 2.days.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true
    })
    CurrentScope::Event.create!(**base, created_at: 1.day.ago, details: {
      "permission" => "reports#index", "reason" => "no_grant", "record_less" => true,
      "model" => "Report"
    })

    output = run_task

    assert_match(/^\s+2\s+would-be denials STILL ungranted/, output,
      "no grant exists, so neither row is answered")
    assert_match(/Total: 2 outstanding would-be denial\(s\)/, output,
      "the list below the headline must count the same denials the headline does")
    assert_match(/reports#index \*/, output,
      "and the line includes the legacy row, marked as the caveat says")
  end

  # #196 review — `model:` only changes the record-less arm, so a row that names
  # a live record is answerable with or without one. Refusing to re-check it
  # because the recorded type was since renamed would strand it as outstanding
  # for ever, and no grant could clear it: the unreachable exit condition #190
  # fixed, one layer down.
  test "a record-bound denial is re-checked even when its recorded model is gone" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    role = CurrentScope::Role.create!(name: "Reader")
    role.role_permissions.create!(permission_key: "reports#show")
    CurrentScope::RoleAssignment.create!(subject: alice, role: role)
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: alice.to_gid.to_s, actor: alice.to_gid.to_s,
      target: report.to_gid.to_s, target_label: report.title,
      details: { "permission" => "reports#show", "reason" => "no_grant",
                 "record_less" => false, "model" => "LongDeletedThing" }
    )

    output = run_task

    assert_no_match(/could not be re-checked/, output,
      "the record loads and the grant answers it; the dead type name is irrelevant here")
    assert_match(/nothing to act on|Every would-be denial/, output,
      "so the grant clears it and the loop can still reach zero")
  end

  # #116 — the survey cannot see a request that never resolved a subject, and that
  # is the class that 403s FIRST after the flip. An operator reading "0
  # outstanding" must not read it as "ready".
  test "the caveat names the unauthenticated blind spot, so zero does not read as ready" do
    # Deliberately an EMPTY ledger: this is the zero case the name describes, and
    # the caveat must survive the branch that prints "nothing found in any
    # category". Seeding a denial here would assert the caveat in the one
    # scenario where it was never in doubt.
    output = run_task

    assert_match(/before authentication/, output)
    assert_match(/recorded\s+NOWHERE/i, output)
    assert_match(/WILL be refused after the flip/, output)
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

  # #183: the declaration is a validation, so it judges a row when that row is
  # written and never again. A host that adds a declaration to close a widening
  # has not touched the grants already in the table — and those are the rows the
  # feature was opened for, so the scan names them.
  test "a grant its type would refuse today is named, though the row still resolves" do
    project = Project.create!(name: "Q3")
    role = role_with("projects#show")
    scope_grant(@alice, role, project)
    declare_grantable_roles(Project, [ "Someone Else" ])

    out = run_task

    assert_match(/no longer accepts/, out)
    assert_match(/Q3|Project##{project.id}/, out)
    assert CurrentScope::ScopedRoleAssignment.exists?(subject: @alice, resource: project),
           "the row is reported, not touched — revoking is the operator's call"
  end

  # An orphaned grant resolves to nothing, so it is not one of the rows this
  # section is about — and the heading tells the operator these still resolve
  # (#183).
  test "a grant whose record is gone is not named among the non-conforming" do
    project = Project.create!(name: "Q3")
    role = role_with("projects#show")
    scope_grant(@alice, role, project)
    declare_grantable_roles(Project, [ "Someone Else" ])
    project.delete

    refute_match(/no longer accepts/, run_task)
  end

  test "a grant its type still accepts is not named" do
    project = Project.create!(name: "Q3")
    role = role_with("projects#show")
    scope_grant(@alice, role, project)
    declare_grantable_roles(Project, [ role.name ])

    refute_match(/no longer accepts/, run_task)
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
