---
title: The exit condition nobody can reach, and the test that passes against the bug
module: lib/tasks/current_scope_tasks.rake
date: 2026-08-23
problem_type: workflow_issue
component: development_workflow
category: workflow-issues
severity: high
applies_when:
  - "Writing or reviewing a report, check, or gate whose documented exit condition is 'until the list is empty'"
  - "Reading counts off an append-only event ledger that records past decisions"
  - "Adding a time window, a flag, or a fallback that decides between a permissive and a restrictive answer"
  - "Writing a test that pins a bug in code that returns a verdict computed from several inputs"
  - "Signing off on an adoption step that has never been walked end to end against a real app"
symptoms:
  - "A grant is applied, the traffic passes, and the report prints a byte-identical list with the same headline count"
  - "A mistyped window value prints the exact 'nothing found' text the guide tells the operator to act on"
  - "An item drops out of the report because it was not exercised recently, not because it was fixed"
  - "A record-less denial stays outstanding forever, or a denial on the subject's own record re-checks on the wrong arm"
  - "A test named for the zero case seeds a row, so the zero branch never runs and the test still passes"
root_cause: missing_workflow_step
resolution_type: code_fix
related_components:
  - "testing_framework"
  - "tooling"
  - "documentation"
  - "lib/tasks/current_scope_tasks.rake"
  - "lib/current_scope/guard.rb"
  - "test/report_task_test.rb"
  - "docs/guides/adopting-in-an-existing-app.md"
tags:
  - "exit-condition"
  - "false-all-clear"
  - "append-only-ledger"
  - "test-that-passes-against-the-bug"
  - "assert-the-question-not-the-verdict"
  - "adoption-rollout"
  - "report-task"
related_issues:
  - "#116 (open): the real-host :report to :enforce bake that gates 1.0"
  - "#184 (merged as 25c2f9f): the report re-checks each recorded denial against live grants"
---

# An exit condition nobody can reach, and the tests that pass against the bug

## Context

Issue #116 is the last gate before this gem goes 1.0, and it asks for one human step: a
real host sets `config.enforcement = :report`, runs `bin/rails current_scope:report`,
grants what the report names, and flips to `:enforce`. That step had never been
completed. It was assumed to be a scheduling problem. It was not. The instrument the
step depends on had no reachable finish line.

Three facts, each in one place in the tree:

**The ledger only grows.** `CurrentScope::Event` is append-only by design:
`app/models/current_scope/event.rb:24` is `def readonly? = persisted?`, and the class
header (`event.rb:15-19`) is explicit that this AR-level ceiling is honest but not
total, naming `update_all` / `delete_all` / `update_column(s)` / `insert_all` / raw SQL
as the operations that bypass it. Nothing in the normal path rewrites or removes a row.

**Every would-be denial writes one row.** In report mode the gate observes and proceeds:
`Guard#report_would_deny` (`lib/current_scope/guard.rb:364-371`) logs, sets the
`X-Current-Scope-Reason: would_deny` header, and calls `record_would_deny_event`
(`guard.rb:438-460`), which appends an `access.would_deny` event. Two details of that
method matter later. It returns early when there is no ambient subject
(`guard.rb:439-443`: "No ambient subject, nothing to attribute the row to"), which is
why an unauthenticated request is recorded nowhere. And it stores
`target: target || subject` (`guard.rb:458`) so the ledger's target column is never
null. Its sibling `record_sod_blind_spot_event` does the same two things
(`guard.rb:396-397` and `guard.rb:405`).

**The report counted rows.** So granting a permission could never reduce the number.
The append-only ledger answers "what was ever denied"; the operator's question before
flipping is "what would still be denied". The adoption guide told them, in three places,
to grant until the list empties and then flip. The old wording in
`docs/guides/adopting-in-an-existing-app.md` read: "Seed the roles it names, watch the
list empty out, then set `config.enforcement = :enforce`." That could not happen.

It was found by **walking** the rollout against the dummy app instead of reading about
it: grant the exact keys the report names, replay the traffic (200s, no `would_deny`
header, so the grants demonstrably worked), re-run the report, and get a byte-identical
list under the same headline count.

PR #184 shipped the fix. The report now re-checks each recorded denial against live
grants, once per distinct subject / permission / target, and counts only what would
still be denied (`lib/tasks/current_scope_tasks.rake:169-240`). A pair it cannot
re-check counts as outstanding, never as ready.

**The part worth keeping is not the fix. It is that the fix took five rounds, and every
round was the same class of defect: an exit condition that cannot be reached, or an
all-clear that can lie.**

1. The original: counting rows in an append-only ledger.
2. A `SINCE=` time window, the first fix attempt. Abandoned, not patched.
3. Passing `record: nil` on the re-check, so a denial only a scoped grant would clear
   stays outstanding forever.
4. Inferring "record-less" from `target_gid == subject_gid`, which a denial on the
   subject's own record looks exactly like.
5. Reading the `record_less` flag off `group.first`, so a legacy row and a flagged row
   sharing a key get one answer applied to both.

And a second pattern, sharper: **three of the tests written to pin this passed against
the bug they were written to pin.** They only became real when they stopped asserting a
downstream verdict and started asserting which question was asked.

## Guidance

### Rule 1: state the exit condition as something the operator can reach and verify

A procedure that ends "when the list is empty" is a promise about a number. Before you
write it, name the operation that makes the number go down. If there is no such
operation, the procedure has no end, and every operator who follows it concludes the
tool is broken or that they are.

Then ask the second question, which is the one that keeps biting: **can the all-clear
appear for any reason other than the work being done?** An exit condition that a typo, a
clock, or an empty database can satisfy is worse than no exit condition, because it is
acted on.

Concretely, in this repo:

*Before (report headline and guide, up to PR #184).* The task counted
`access.would_deny` rows. The guide said "watch the list empty out, then set
`config.enforcement = :enforce`". The decreasing operation did not exist.

*After.* The rake task groups the rows and asks the resolver again
(`current_scope_tasks.rake:191-240`), splitting into `outstanding`, `resolved` and
`unknown`. The headline counts denials, not pairs, so the summary and the detail list
cannot disagree (`current_scope_tasks.rake:308-319`):

```ruby
"would-be denials STILL ungranted (grant these)" =>
  outstanding.sum { |pair| pair[3] } + unknown.sum { |pair| pair[3] },
```

The guide now names the mechanism rather than the appearance
(`docs/guides/adopting-in-an-existing-app.md:49-58`):

> Seed the roles it names, re-run the report until nothing is **still ungranted**, then
> set `config.enforcement = :enforce`.
>
> **What "empty" means here.** The ledger is append-only, so a would-be denial stays
> listed after you grant it. The report therefore re-checks every recorded denial
> against your live grants and counts only the ones that would *still* be denied today.

Three properties make that count usable, and each is a separate decision:

- **"Cannot tell" is counted on the not-ready side.** A subject or record that no longer
  resolves goes to `unknown` (`current_scope_tasks.rake:222-228`), `unknown` is added
  into the headline, and the operator is told why
  (`current_scope_tasks.rake:335-340`): "They are counted as OUTSTANDING above: cannot
  tell is not the same as ready."
- **The all-clear is a sentence, not a zero.** When `outstanding` and `unknown` are both
  empty and anything was resolved, the report says so in the operator's own words
  (`current_scope_tasks.rake:328-334`): "The ledger still lists them because it is
  append-only. That is the list you were waiting to see empty; this is what empty looks
  like." A bare zero is indistinguishable from a tool that recorded nothing.
- **What the tool cannot see is printed next to what it found.** The caveat
  (`current_scope_tasks.rake:346-355`) prints unconditionally and names the blind spot
  that 403s first after the flip: a request reaching the gate before authentication is
  downgraded, recorded nowhere, and refused the moment you flip. The same warning was
  added to step 5 of the rollout ladder (`adopting-in-an-existing-app.md:406-413`),
  which is where an operator actually plans the flip, rather than only in output they
  may skim.

### Rule 2: assert the question your change controls, not a downstream verdict

When your change decides **what to ask** a collaborator, assert the arguments it passes.
Do not assert the collaborator's answer. The answer depends on state the test also sets
up, and that state can make both the right question and the wrong question return the
same value. Then the test is green in both worlds and pins nothing.

This is exactly what happened three times here. The report's job is to re-ask
`CurrentScope.resolver.allow?`
(`lib/current_scope/resolver.rb:41`:
`def allow?(subject:, permission:, record: nil, actor: nil, model: nil, cascade: true)`)
with the same record the gate asked about. The defect in rounds 3 to 5 was always that
the wrong `record:` went in. Every attempt to pin it by asserting the printed verdict
passed against the bug, because whether a wrong `record:` changes the verdict depends on
which resolver arm the test's grants happen to hit.

*Before (an attempt that passed both ways).* Seed a record-less denial, grant an
org-wide role, assert the report prints it as resolved. An org-wide grant allows
regardless of record, so `record: nil` and `record: alice` give the same verdict. A
second attempt used a scoped grant instead, and the resolver arm the fix was about never
fired for that setup.

*After (`test/report_task_test.rb:109-135`).* Capture the kwargs:

```ruby
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
```

The test's own comment states the rule (`test/report_task_test.rb:117-119`): "Assert the
QUESTION, not a downstream answer: whether the difference is visible in the verdict
depends on which resolver arm the host's grants happen to hit, and the defect is that
the wrong question is asked at all."

Two corollaries, both paid for on this feature:

- **Record the fact where it is known, rather than inferring it downstream.** Rounds 4
  and 5 existed because the report tried to reconstruct, from stored GIDs, something the
  gate knew for certain. The fix moved the fact to the gate: `record_less` is now written
  on the row (`guard.rb:457-459`), and `guard.rb:451-456` says why in place, so the next
  reader does not re-invent the inference.
- **A test named for the empty case must run empty.** The blind-spot test seeded a
  denial row, so the run was never empty and the branch its name describes never
  executed. It now runs against an empty ledger (`test/report_task_test.rb:203-213`),
  with the reason written down: seeding a denial "would assert the caveat in the one
  scenario where it was never in doubt".

## Why This Matters

**The failure direction is the dangerous one.** Everything else in this engine is
fail-closed: silence at the gate denies, an unprovable SoD veto 403s, a grant that cannot
match is reported. The report is the one component whose failure mode is a *false
all-clear*, and it is read immediately before a human turns enforcement on for a whole
production app. Rounds 4 and 5 were both false all-clears: a denial still in force,
reported as cleared, because the re-check ran on the more permissive arm.

**The store cannot be repaired, so the reader must be.** Append-only is a deliberate
property of the ledger, not an accident (`event.rb:2-20`). There is no compensating
write that retires a `would_deny` row when the grant lands. Any report over such a store
must reinterpret the history against current state, or it is answering a question nobody
asked. The same shape appears wherever an audit log, an event stream, or an error tracker
backs a "are we done yet" number.

**Five rounds is the signal.** Each round was found by review, fixed, and re-reviewed,
and each fix reintroduced the same class one layer down. The commit messages on PR #184
say so out loud: "That is the unreachable exit condition again, one layer down" and
"Same false all-clear, one layer further in". Once a review returns the same class twice,
the useful move is to stop patching the instance and name the class, then re-read the
whole change for other instances of it. That is what produced the `record_less` flag and
the grouping key, instead of a third guess about GIDs.

**A green suite proved nothing here, three times.** Three tests written specifically to
pin this defect passed against it. Two hid behind a grant that made both questions
return the same verdict; one hid behind seeded data that skipped its own branch. A test
is a pin only when you have watched it fail against the defect. Every test kept in
PR #184 was proved red first.

## When to Apply

- You are writing any instruction of the form "repeat until the list is empty / the
  count is zero / the warnings stop". Name the operation that decreases it before you
  ship the sentence.
- The number comes from a store that only grows: an audit ledger, an event table, a log
  index, an issue tracker with no close step in your loop.
- A tool prints an all-clear that a human acts on irreversibly. Ask what else can produce
  that output: an empty database, a mistyped filter, a clock, a permission error that was
  swallowed.
- Your change decides what to pass to another component, rather than what to conclude
  from its answer. Assert the call, not the conclusion.
- A test's name mentions zero, empty, none, or first-run. Check that the scenario it sets
  up actually is that case.
- The same reviewer finding comes back a second time on the same change in a new shape.
  Treat it as a class, not as another instance.

## Examples

### Example 1: the count that could only go up

The gate appends one row per would-be denial and never removes it
(`guard.rb:438-460`, `event.rb:24`). The report counted those rows. The rollout said
grant until it empties.

The walk that proved it, against the dummy app: grant the exact keys the report named,
replay the traffic and confirm the grants worked (200 responses, no
`X-Current-Scope-Reason: would_deny` header, which is the header `report_would_deny` sets
at `guard.rb:369`), then re-run the report and get an identical list under an identical
headline. Reading the task's source made the row count look reasonable. Running the
documented loop end to end is what made it obviously unfinishable.

### Example 2: the `SINCE=` window, abandoned rather than patched

The first fix attempt filtered the ledger to a recent time window, on the theory that
old rows are stale. Three reviewers found the same shape of hole:

- A mistyped value passes the parser and lands somewhere harmless-looking. `SINCE=1H`
  parses as 01:00 today. `SINCE=30M` lands in the future. Either prints the exact
  "nothing found" text the guide tells the operator to wait for.
- A permission exercised less often than the window drops out of the report whether or
  not it was ever granted.

Both are the original defect wearing different clothes: an all-clear with a cause other
than the work being done. It was reset rather than patched, and the re-check against live
grants replaced it. There is no `SINCE` code in the tree to find, which is the point:
the wrong exit condition was removed, not narrowed.

### Example 3: two denials that look identical in the ledger

`guard.rb:458` writes `target: target || subject` so the target column is never null.
That makes a **record-less** denial (a collection action, where
`current_scope_record` returned nil) and a denial **on the subject's own record**
(`users#update` on yourself) store the same GID. Round 4 guessed record-less from that
equality, which re-checks on the more permissive arm, so a still-denied self-targeted
denial could be reported as resolved.

The fix records the fact at the point where it is known, and says why in place
(`guard.rb:451-459`):

```ruby
# `target: target || subject` keeps the ledger's target non-nil, which means
# a record-less denial and a denial ON THE SUBJECT'S OWN RECORD both store
# the subject's GID. Only this side knows which it was, so say so: the #116
# report re-asks the resolver and must ask with the same record the gate
# did. Inferring it from equal GIDs would read a self-targeted denial as
# record-less and re-check on the more permissive arm.
CurrentScope::Event.record!(
  event: "access.would_deny", target: target || subject,
  details: { permission: permission, reason: "no_grant", record_less: target.nil? }
)
```

Round 5 was the residue: rows written before that flag existed carry no `record_less`,
and a legacy row can share a subject, permission and target with a flagged one. Reading
the flag off one member of the group applied one row's answer to the other. The flag is
now part of the grouping key (`current_scope_tasks.rake:187-194`), so a group is uniform
by construction and the legacy rows fall back to the ambiguous GID comparison on their
own (`current_scope_tasks.rake:220-221`).

### Example 4: the three tests that passed against the bug

| Test | Why it passed against the defect | What made it real |
| --- | --- | --- |
| record-less denial re-checks with no record | The setup used an org-wide grant, which allows regardless of record, so `record: nil` and `record: alice` produced the same verdict | Capture the kwargs; assert `asked.first[:record]` is nil (`test/report_task_test.rb:109-135`) |
| second attempt at the same test | Switched to a scoped grant, but the resolver arm under test never fired for that setup | Same capture, same assertion on the input |
| "zero does not read as ready" | Seeded a `would_deny` row, so the run was non-empty and the zero branch its name describes never ran | Run against an empty ledger (`test/report_task_test.rb:203-213`) |

The two sibling tests use the same capture to pin the other half of the pair: a
self-targeted denial must re-check **with** its record
(`test/report_task_test.rb:141-164`), and a legacy row plus a flagged row for one key
must produce two re-checks, one with each (`test/report_task_test.rb:169-198`). That
last one compares the captured records as a set, because the ledger query has no
`ORDER BY` and the property under test is that both questions get asked, not the order
they arrive in.

## Related
- [The crash that was holding the door](../design-patterns/the-crash-that-was-holding-the-door.md):
  its sibling from the same session and the same engine. That one is about a
  predicate that can lie ("nobody holds full access" when the truth is "cannot
  tell"); this one is about a number that can. Both landed on the same rule from
  opposite directions.

- [A correction is a rot event](a-correction-rots-the-plan-it-fixes.md): the sibling
  about the same session's other recurring shape, a fix applied to the reasoning and left
  stale in the instructions. That happened three times running on one plan in this
  session, which is the same "review returns the same class, patch the instance" trap
  described under Why This Matters.
- [A plan is intent to verify, not instructions to follow](plan-code-sketches-are-intent-not-code.md):
  why a written procedure's instruction half is the half that ships, which is what made
  "watch the list empty out" survive in three places.
- [SimpleCov reports a number that is quietly wrong](simplecov-reports-a-number-that-is-quietly-wrong.md):
  the nearest cousin. A tool whose one job is to print a number, printing a wrong one
  with nothing failing and a green suite.
- **Issue #116**: the real-host `:enforce` bake, still the last gate before 1.0.
- **PR #184** (merged as 25c2f9f): the exit condition, and the five review rounds quoted
  above.
- **PR #185**: the unauthenticated blind spot, and the empty-ledger test fix.
