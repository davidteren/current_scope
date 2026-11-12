---
title: Report Diagnosis Extraction - Plan
type: refactor
date: 2026-09-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/140
---

# Report Diagnosis Extraction - Plan

Issue #140 asks to extract repeated report-mode recording and to move report printing out of the rake task.
Behavior stays the same.
Paths below were read on `origin/main` at `a3d4fef`.
This branch has no `DenialSurvey` class. The rake task keeps today's re-check loop. The printer only formats the buckets that loop already built. If a later change adds `DenialSurvey.denials`, the task passes that result in and deletes its own loop. The printer still does not classify.

## Goal Capsule

- **Objective:** One private helper records the three report-mode ledger rows, and one object renders the report sections the rake task prints today.
- **Authority hierarchy:** this plan, then issue #140, then the report sentences pinned by `test/report_task_test.rb`, then `AGENTS.md`.
- **Execution profile:** Move code. Do not change event names, detail keys, rescue behavior, or report sentences.
- **Stop conditions:** Do not merge the three events into one event. Do not change `record_would_deny_event`'s required `model` argument. Do not re-query inside the printer if a summary object already holds the buckets.
- **Tail ownership:** The preflight headline from issue #187 stays in that task. This plan does not print a flip verdict.

---

## Product Contract

### Summary

`Guard` has three recorders that each rescue `StandardError`, warn once, and attach a different sentence about what the request did.
The report rake task both classifies and prints.
Splitting those jobs makes the next report change local. It must not change what an operator reads or what the ledger stores.

### Problem Frame

The three methods are `record_sod_initiator_missing_event` (`lib/current_scope/guard.rb` line 259), `record_sod_blind_spot_event` (line 401), and `record_would_deny_event` (line 444).
They share a shape and they do not share an outcome sentence.
Collapsing the sentences would send an operator after the wrong failure.
The rake task at `lib/tasks/current_scope_tasks.rake` line 144 is a long printer. The classification it performs is the product. The printing is not.

### Requirements

- R1. The three ledger events stay `access.sod_initiator_missing`, `access.sod_blind_spot`, and `access.would_deny`.
- R2. Each event keeps its current details keys and its current `request_outcome` sentence in the ledger-failure warning.
- R3. A ledger failure still warns once per process through `warn_ledger_failure_once`, and still does not raise.
- R4. `record_would_deny_event` still requires `model`. Callers do not gain a default.
- R5. Building the event and writing it stay separate where they are separate today, so a build failure does not consume the one warning the other recorders need.
- R6. The rake task gathers, or accepts, the buckets and prints what a report object returns. Section order and sentences stay those pinned by `test/report_task_test.rb`.
- R7. The printer does not run a denial classifier. On this branch the rake task keeps gathering and passes the finished buckets in. The printer only formats those buckets.

### Scope Boundaries

- No new section and no removed section.
- No change to moot, unknown, or outstanding rules.
- No change to issue #142's class-level model hook. That is a different plan.
- Guard remains the place that decides to record. The helper only performs the write shape.

### Sources

- `lib/current_scope/guard.rb` lines 259, 401, and 444.
- `lib/tasks/current_scope_tasks.rake` from the report task at line 144 through the print block.
- `test/report_task_test.rb`.
- `test/integration/report_only_test.rb`.
- `docs/plans/2026-09-29-001-feat-enforce-preflight-plan.md` when that file is present.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. Add one private method on `Guard`, called by the three recorders, with the event name, the details, the target, and the `request_outcome` sentence as arguments. Each recorder keeps its own lead-in, including the subject-nil return and the target rules.
- KTD-2. Do not put the three outcome sentences in one hash keyed only by event name if that hash becomes the only spec. The sentences stay written at the three call sites so a reader sees the request outcome next to the event.
- KTD-3. Put the formatter in `CurrentScope::ReportPrinter` under `lib/current_scope/`. It accepts the buckets and returns the string the rake task prints. The rake task `puts` that string. It does not rebuild the sections.
- KTD-4. Do not call `DenialSurvey` from this change. That class is not in the code. Leave gathering in the rake task. Do not copy the classifier into the printer. A later issue #187 change may pass `DenialSurvey.denials` in and delete the rake loop. This plan does not do that.

### Sequencing

- U1 extracts the recorder helper and keeps ledger-failure tests green.
- U2 moves printing behind `ReportPrinter` and keeps report-task strings green.

### Risks

- A shared rescue around event construction would trip the one-shot warning for the other two events. The initiator path rescues construction and returns before the write (`guard.rb` lines 263 to 270). The would-deny path rescues a model-name failure, omits the `model` key, and still writes the row (`guard.rb` lines 497 to 503). Those are two splits. U1 keeps both.
- `test/report_task_test.rb` matches fragments. A one-space edit on an unmatched line stays green. The pin is a diff of the printer text against the old `puts` lines, plus no edits to expected strings. A red test means restore the sentence. Do not rewrite the sentence or the expectation.

---

## Implementation Units

### U1. One recorder shape

- **Goal:** The three recorders delegate the write-and-rescue shape without changing events or warnings.
- **Requirements:** R1, R2, R3, R4, R5
- **Dependencies:** none
- **Files:**
  - `lib/current_scope/guard.rb`
  - `test/integration/report_only_test.rb`
- **Approach:** Add the private helper. Pass event, details, target, and the outcome sentence. Leave `model` required on `record_would_deny_event`. Keep both build-versus-write splits: the initiator path returns before the write, and the would-deny path still writes the row when the model name raises and omits the `model` key.
- **Patterns to follow:** The comment at lines 263 to 270 and the model-name rescue at lines 497 to 503. Do not fold those into one rescue.
- **Test scenarios:** Each event name is still written on its path. A raised `Event.record!` warns with that path's outcome sentence and does not raise to the request. `record_would_deny_event` still rejects a call that omits `model`. When the model name raises, the row is still `access.would_deny`, the `model` key is absent, and the one-shot warning is still armed.
- **Verification:** Existing report-only examples pass without changed event names or warning text.

### U2. Move report printing

- **Goal:** The rake task prints a string built by `ReportPrinter` from the same buckets as today.
- **Requirements:** R6, R7
- **Dependencies:** U1
- **Files:**
  - `lib/current_scope/report_printer.rb` (new)
  - `lib/tasks/current_scope_tasks.rake`
  - `test/report_task_test.rb`
- **Approach:** Move the `puts` blocks into the printer as a returned string. Keep gathering in the rake task (KTD-4). Diff the printer text against those old lines. Do not add a headline the report task does not already print. Do not edit an expected string to absorb a wording change.
- **Patterns to follow:** The report task's existing sentence text is the spec. Copy it into the printer unchanged.
- **Test scenarios:** Every example in `test/report_task_test.rb` keeps its expected string. A printer test, if added, asserts against those same sentences rather than a new wording.
- **Verification:** `test/report_task_test.rb` passes with no expectation edits. A diff of expected strings is empty.

---

## Verification Contract

| Check | Command | Proves |
|---|---|---|
| Report behavior | `bin/rails test test/report_task_test.rb test/integration/report_only_test.rb` | R1 to R7 |
| Lint | `bin/rubocop` | Style |

One test process per checkout.

## Definition of Done

- The three events, their details, and their failure sentences are unchanged.
- `model` is still required for the would-deny recorder.
- The report task's expected output is unchanged.
- There is one printer object and no second classifier.
- Abandoned experiments are not left in the diff.
