---
title: Definitions Apply Lock Bound - Plan
type: fix
date: 2026-09-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/178
---

# Definitions Apply Lock Bound - Plan

Issue #178 has two parts.
The undo-file race shipped in #223 (`with_snapshot_lock` in `lib/current_scope/definitions_document.rb` at line 441).
This plan covers only the remaining part: the console lock loads every matching assignment id into one statement.
Paths below were read on `origin/main` at `a3d4fef`.

## Goal Capsule

- **Objective:** Bound the assignment-id list that `FullAccessLock.lock_console_state!` sends to the database, and still refuse a definitions apply that would leave no live full-access holder.
- **Authority hierarchy:** this plan, then issue #178, then the last-holder rules already in `FullAccessLock`, then `AGENTS.md`.
- **Execution profile:** Page assignment locks inside `lock_console_state!` and the planned-name liveness scan. Do not change the snapshot file lock. Do not change resolver order.
- **Stop conditions:** Do not use `LIMIT 1` as the answer. A blank or unresolvable subject is not a holder. Do not stop early unless a live holder of a planned full-access name is locked. Registry-blind still refuses.
- **Tail ownership:** Cross-host locking stays out of scope. `flock` is same-machine only, and #223 already says so.

---

## Product Contract

### Summary

Promoting a widely held role builds one `IN (...)` list of every current full-access assignment plus every assignment of the names the document plans to make full access.
That list is unbounded.
The lock will take the same rows in id order, in pages small enough for every supported adapter, and the liveness decision will stop only when it has locked a real holder.

### Problem Frame

`lock_console_state!` (`lib/current_scope/full_access_lock.rb` lines 14 to 26) plucks every matching assignment id and locks them in one statement.
`would_lose_held_full_access?` (line 93) then asks `live_holder?` (line 34), which loads those rows and stops at the first subject that resolves.
The Ruby stop does not stop the pluck.
A page of inert rows must not be allowed to answer "the console stays open".

### Requirements

**Bound**

- R1. Each assignment lock statement binds at most one page of ids. The page size is 100 in production code and is readable by tests so a test can set it to 1.
- R2. Role rows are still locked first, all of them, in id order, in one statement. The role table is the small set.
- R3. Current full-access assignment ids are locked in full, in id order, page by page. There is no early stop on that set. Those rows are the last-holder set.
- R4. Planned-name assignment ids use their own keyset, after the current full-access ids are locked. The first planned page starts at the lowest planned id. It does not start after the highest current full-access id. An id already locked in R3 is not locked a second time. That skip is in Ruby after the page is read. The row is still tested with the liveness rule. Do not drop already-locked ids with a `NOT IN` list. That list would remove the bound.

**Decision**

- R5. The scan may stop before the last planned-name page only after it has locked a live holder of a planned full-access name. After that holder is locked, and the registry was not blind, later pages are not read. A later unread error does not undo the locked holder.
- R6. An inert page does not answer the question. A blank, deleted, or unresolvable subject is not a live holder. The scan continues.
- R7. If no planned page contains a live holder, the scan locks every remaining planned page and then reports that no planned live holder exists. That report is not the whole would-lose answer. Apply refuses only when a current live holder exists and no planned live holder was locked. No current live holder still allows apply. The empty-table import test pins that allow.
- R8. `registry_blind?` still refuses before the planned-name scan treats the console as safe. A `ConfigurationError` during the scan still refuses.
- R9. Two applies still lock role ids and assignment ids in ascending id order, so paging cannot deadlock them with each other.

**Out of the lock file**

- R10. This change does not alter `with_snapshot_lock`, undo filenames, or snapshot restore.

### Acceptance Examples

- AE1. Page size 1, first planned assignment is inert, second is a live holder.
  - **Covers:** R5, R6
  - **Given:** the first planned-name assignment does not resolve, and the next one does.
  - **When:** apply asks whether the document would drop the last live holder.
  - **Then:** the answer is no, and the inert row was not treated as the holder.
- AE4. Page size 1, the only live planned holder has a lower id than the current full-access assignment.
  - **Covers:** R3, R4, R5
  - **Given:** one current full-access assignment exists, and one live assignment of a planned full-access name has a lower id.
  - **When:** apply asks the same question.
  - **Then:** that lower id is locked and tested, and the console stays open.
- AE5. Page size 1, the only live planned holder is already a current full-access assignment.
  - **Covers:** R4, R5
  - **Given:** one live assignment is full access today and its role name is also in the planned names.
  - **When:** apply asks the same question.
  - **Then:** the console stays open, that id is locked once, and the liveness rule still saw the row.
- AE2. Page size 1, every planned assignment is inert, and a live full-access holder exists today.
  - **Covers:** R7
  - **Given:** no planned name has a live holder.
  - **When:** the same question is asked.
  - **Then:** the answer is yes, the console would lose its last live holder, and every page was locked.
- AE3. The process cannot resolve subject types.
  - **Covers:** R8
  - **Given:** `registry_blind?` is true.
  - **When:** apply asks the question.
  - **Then:** apply refuses.

### Scope Boundaries

- Do not replace the scan with `EXISTS` or with `LIMIT 1`. Liveness is decided in Ruby because a row can point at a gone subject.
- Do not take a cross-host lock. The snapshot `flock` stays as #223 shipped it.
- Grant controllers already lock recipient rows before they call this method. This plan does not reorder those locks.
- A new assignment inserted after a page was plucked can sit in the same window the current pluck-then-lock path already has. Do not build a second lock protocol for that window.

### Sources

- `lib/current_scope/full_access_lock.rb` lines 14 to 102.
- `lib/current_scope/definitions_document.rb` `with_snapshot_lock` at line 441.
- `test/full_access_lock_assignment_test.rb`.
- `test/definitions_import_test.rb` around the snapshot-lock examples (the file lock stays covered there).

---

## Planning Contract

### Key Technical Decisions

- KTD-1. Page with a keyset on assignment id, not with `OFFSET`. The current full-access relation and the planned-name relation each keep their own cursor. Do not reuse the highest current full-access id as the planned-name start. A page is the next ids of that one relation, ordered by id, limited to the page size. Lock ids on that page that are not already locked, in id order. On a planned-name page, run the liveness rule on every visited id, including an id R3 already locked.
- KTD-2. The page size lives in `FullAccessLock::ASSIGNMENT_LOCK_PAGE_SIZE` and is read through a method tests can stub. It is not a host configuration setting.
- KTD-3. Early stop is only for the planned-name liveness question inside `would_lose_held_full_access?`. The current full-access set is locked in full because those rows are what a concurrent demotion would remove.
- KTD-4. `live_holder?` stays the liveness rule: strict `polymorphic_class` per distinct token, then `current_scope_resolved_record("subject")`. The pager calls that rule per page instead of copying it.
- KTD-5. The snapshot file lock is finished work. Do not reopen filename uniqueness or `flock`.
- KTD-6. Definitions apply today calls `lock_console_state!(planned_fa)` and then `would_lose_held_full_access?(planned_fa)` (`definitions_document.rb` lines 333 and 337). Replace that pair with one walker that locks roles, page-locks current full-access ids, page-walks the planned ids, and returns the would-lose boolean. Keep the role-permission lock and `refuse_held_deletes!` that sit between those two calls (lines 334 to 336). The walker rescues `ConfigurationError` the way `would_lose_held_full_access?` does today: latch the registry message and return true. It does not raise before `refuse_held_deletes!`. `HeldRoleDelete` still wins when both apply. Raise `LastHolderLock` only after `refuse_held_deletes!` returns. Do not also call `lock_console_state!` with the planned names. `would_lose_held_full_access?` uses the same walker, so it takes those locks inside the caller's open transaction. The question name stays. Callers that only need the boolean must already be in that transaction. `lock_console_state!` with no planned names stays the console-controller lock, and it page-locks the current full-access ids.

### High-Level Technical Design

Inside the open transaction the order is: lock all roles by id, page-lock every current full-access assignment id on one keyset, then page through planned-name assignment ids on a second keyset.
On each planned page, resolve liveness.
Stop when a live holder is locked.
If the pages end without one, the planned names do not hold a live full-access subject. Apply still allows the document when no current live holder exists.
`held_full_access?` still uses the current full-access rows, which are already locked.

### Assumptions

- A page of 100 integer ids is under the bind limit of SQLite, MySQL, and PostgreSQL. The test suite already runs on all three.
- Role count stays small enough to lock in one statement. That is the existing comment in `lock_console_state!`.
- Definitions apply changes role flags. It does not delete the assignment row of the holder this scan relies on. The locked live holder of a planned full-access name is still a holder at commit.

### Sequencing

- U1 adds the pager and uses it from `lock_console_state!` and `would_lose_held_full_access?`.
- U2 pins the inert-first-page case, the no-holder case, and the registry-blind case at page size 1.

### Risks

- Stopping on an inert row would let apply remove the last real holder. AE1 is the pin that forbids that.
- Locking pages in a different order than id order can deadlock two applies. R9 is the pin.
- Stubbing the page size through configuration would make a safety bound look like a product setting. KTD-2 forbids that.

---

## Implementation Units

### U1. Page the assignment locks

- **Goal:** `lock_console_state!` and the planned-name half of `would_lose_held_full_access?` bind at most one page of assignment ids per statement.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9, R10
- **Dependencies:** none
- **Files:**
  - `lib/current_scope/full_access_lock.rb`
  - `lib/current_scope/definitions_document.rb` (the two calls at lines 333 and 337 become one)
- **Approach:** Add the page-size constant and reader. Add one walker used by the definitions-apply call and by `would_lose_held_full_access?` (KTD-6). The walker locks roles, page-locks every current full-access id on one keyset, then page-walks planned-name ids on a second keyset that starts at the lowest planned id. It runs the liveness rule on each visited planned id, including an id already locked, and it does not lock that id again. It stops when a live planned holder is locked. If the walk ends, a missing planned holder refuses only when a current live holder exists. In `definitions_document.rb`, keep the role-permission lock and `refuse_held_deletes!` between the walker and the `LastHolderLock` raise. The walker returns true on `ConfigurationError` instead of raising, so that check still runs. Do not call `lock_console_state!` with the planned names. `lock_console_state!` with no planned names still page-locks current full-access ids. Leave `with_snapshot_lock` untouched.
- **Patterns to follow:** The comment on `lock_console_state!` (roles first, then assignments, id order). The comment on `live_holder?` (an unresolvable subject is not a holder, and `any?` stops at the first live one).
- **Test scenarios:** Covered in U2. This unit does not add a new public task or a host-facing setting.
- **Verification:** A read of the method shows no single pluck of the whole planned-name id list, and role locks still happen before any assignment lock.

### U2. Prove an inert page is not an answer

- **Goal:** Page size 1 distinguishes an inert first row from a later live holder, and still refuses when nobody live holds a planned name.
- **Requirements:** R5, R6, R7, R8
- **Dependencies:** U1
- **Files:**
  - `test/full_access_lock_assignment_test.rb`
- **Approach:** Stub the page-size reader to return 1. Build the AE1 and AE2 assignment rows. Assert the would-lose answer and that the test can see the later holder was required. Keep the existing registry-blind example, or add AE3 beside it if coverage is only on the remove path.
- **Patterns to follow:** `test/full_access_lock_assignment_test.rb` from #218. Do not weaken `test/definitions_import_test.rb` snapshot-lock examples.
- **Test scenarios:** AE1 returns "console stays open" only because of the second page. AE4 returns "console stays open" because the lower planned id was visited. AE5 returns "console stays open" because the already-locked id was still tested, and that id was locked once. AE2 returns "would lose" after the inert pages. AE3 returns a refusal when the registry is blind, on the apply question, not only on the remove path. A test that used `LIMIT 1` in SQL would fail AE1. A test that reused the current full-access high id as the planned cursor would fail AE4.
- **Verification:** The three examples pass on the dummy app. The snapshot-lock examples in `test/definitions_import_test.rb` still pass without edits to their expectations.

---

## Verification Contract

| Check | Command | Proves |
|---|---|---|
| Lock behavior | `bin/rails test test/full_access_lock_assignment_test.rb test/definitions_import_test.rb` | R1 to R10 |
| Lint | `bin/rubocop` | Style on the lock file |

The engine suite is the three-adapter net in CI. One test process per checkout.

## Definition of Done

- No assignment lock statement binds an unbounded id list.
- An inert first page cannot keep the console open.
- A live holder on a later page is found and locked before the method says the console stays open.
- A live planned holder with a lower id than the current full-access assignment is still locked and tested.
- An already-locked current full-access id is still tested when it is the planned holder, and it is not locked twice.
- No planned live holder refuses the apply only when a current live holder exists. No current live holder still allows apply. The empty-table import test in `test/definitions_import_test.rb` pins that allow. Every planned page is still locked before that answer.
- Registry-blind still refuses.
- `with_snapshot_lock` and its tests are unchanged in behavior.
- Abandoned experiments are not left in the diff.
