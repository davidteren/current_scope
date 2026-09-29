---
title: Parent Chain Memo - Plan
type: perf
date: 2026-09-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/136
---

# Parent Chain Memo - Plan

Issue #136 asks to cut repeated parent-chain reads on the allow path.
The nested list query is already capped.
This plan memoizes the walk for the rest of the request and records today's query count so it cannot grow.
Paths below were read on `origin/main` at `a3d4fef`.

## Goal Capsule

- **Objective:** Repeated checks of the same record in one request reuse the ancestor list and the ancestor-grant answer. Allow and deny results stay the same.
- **Authority hierarchy:** this plan, then issue #136, then `AGENTS.md` hard rule 1 (fail closed). A wrong cache is worse than an extra query.
- **Execution profile:** Request-local memo on `Current`, plus a query-count pin, plus a guide note. No resolver-order change. No SQL rewrite.
- **Stop conditions:** Do not add a hop-by-hop `exists?` short-circuit. Do not add a recursive CTE. Do not lower the pinned query count in this change. Do not cache across requests.
- **Tail ownership:** A page that checks 100 different records still pays the walk once per record. That limit stays documented. It is not fixed here.

---

## Product Contract

### Summary

`ParentChain.ancestors_for` (`lib/current_scope/parent_chain.rb` line 186) walks one query per hop and does not remember the result.
The org role is already remembered for the request (`CurrentScope::Current#memoized_org_role` at `app/models/current_scope/current.rb` line 63).
Ancestor identity is the same kind of fact for the duration of a request, with one extra key so an in-memory parent change is not served the old list.

### Problem Frame

Scoped-only subjects miss on the org-role arm and then walk the chain.
Doing that walk again for the same record in the same request is pure cost.
Doing it once per distinct record is still required.
`ancestor_scope_for` (`lib/current_scope/resolver.rb` line 432) stops when `path.size` passes `ParentChain::MAX_PARENT_DEPTH` (5). That cap is why this plan does not add a recursive CTE. The five-arm shape can still be about 40 nested selects. This plan does not remove those arms.

### Requirements

**Same answers**

- R1. `allow?` and `scope_for` return the same allow or deny result they return today for the same stored rows. A stored ancestor that later fails `walkable?` on that same object does not keep an allow. A warm ancestor memo is not read when `cascade` is false.
- R2. A miss still denies. The memo must not turn a failed lookup into an allow.

**What is remembered**

- R3. `ancestors_for` stores its result on `Current` for the rest of the request. The key is the record's base class name, its id, and the foreign-key value of its declared parent association.
- R4. The ancestor-grant boolean is stored only after the direct-grant check, after the cascade guard, and only for a saved record. Read and write it only inside `scoped_grant?`, and only after `ancestors_for` returns. Use the stored boolean only when that call was a clean list hit. If the list hit was dropped, or a record guard returned first, compute the boolean from the fresh list and overwrite the key. A destroyed record is that guard: `ancestors_for` returns an empty list before the list memo. Drop that grant key. Do not store the deny. The destroyed check still denies, and the next live check of the same row is computed again. Do not read the memo for an `allow?` call that passes `cascade: false`. The key includes subject class, subject id, permission, record class, record id, and the same declared parent foreign-key value as R3. The key does not need a cascade flag, because the cascade-false path never reads it. A nil id is not stored. `allow?` and `decide` results are not stored. The `scope_for` relation is not stored. `ancestor_scoped_grants` stays a relation, so `allowed_subjects` stays a live query.
- R5. Both memos die with the request. `Current` already resets between requests. This plan does not add a thread-global or process-global cache.
- R6. An in-memory change to the record's declared parent foreign key misses both memos, because that value is in both keys. Deeper in-memory parent edits in the same request are a named residual. That residual is not the org-role memo. The org-role memo is cleared on role writes. The ancestor-grant memo is cleared on the writes in R12.
- R12. Clear the ancestor-grant memo from `Role#reset_cached_permissions`, from `RolePermission#reset_cached_permissions`, and from `ScopedRoleAssignment` after create, after destroy, and after rollback. A `RolePermission` callback alone is not enough. Permission edits use `delete_all` and `insert_all` inside `Role#persist_permission_keys`. The next check in the same request sees the new rows. The ancestor-list memo is parent data and is not cleared by those writes.

**What is not changed**

- R7. The plan does not add per-hop `exists?` probes on the miss path.
- R8. The plan does not replace `ancestor_scope_for` with adapter-specific recursive SQL.
- R9. A test asserts the SQL count of one first two-hop `allow?` equals the count measured on `a3d4fef`. A lower count fails. A higher count fails. If two runs of that example disagree, stop. Do not widen the pin.

**Honest limit**

- R10. The guide states that 100 distinct records still walk once each, and that `includes` on the declared parent association is how a host avoids a query per row when it already has the records.

### Acceptance Examples

- AE1. Two allows for the same grandchild in one request.
  - **Covers:** R3, R4
  - **Given:** a two-hop chain and a grant on the root.
  - **When:** `allow?` runs twice for that record.
  - **Then:** the second call issues no new ancestor query, and both calls allow.
- AE2. Parent foreign key changed in memory before the second call.
  - **Covers:** R6
  - **Given:** the first call cached the chain.
  - **When:** the record's declared parent foreign key is assigned a different id and `allow?` runs again.
  - **Then:** the second call does not reuse the first ancestor list, and its allow or deny result matches a check that never saw the memo.
- AE3. Two different child records.
  - **Covers:** R10
  - **Given:** two children with different ids.
  - **When:** each is checked once.
  - **Then:** each check walks. The memo does not make the second child free.

### Scope Boundaries

- No change to grant matching, `MAX_PARENT_DEPTH`, or storage-token versus `base_class.name`.
- No eager-load inside the engine. The guide only tells the host where to put `includes`.
- Identity-map updates from another object in the same request are the residual in R6. Do not expire the ancestor-list memo on every `save` of every parent. Do expire the grant-answer memo on the writes in R12.

### Sources

- `lib/current_scope/parent_chain.rb` line 186 and `MAX_PARENT_DEPTH` at line 43.
- `lib/current_scope/resolver.rb` `scope_for` at line 153, `ancestor_scope_for` at line 432 (break at line 441), `ancestor_scoped_grants` at line 511.
- `lib/current_scope.rb` `scope_for` at line 240.
- `app/models/current_scope/current.rb` `memoized_org_role` at line 63.
- `docs/guides/checking-permissions.md`.
- Issue #108 shipped the walk. This issue does not reopen that design.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. Memoize both hashes on `Current` for the request lifetime, the same lifetime as `memoized_org_role`. The ancestor-list memo stores the array the walk returns, including an empty array. It does not store a record whose id is nil. The grant-answer memo is not that list, and R12 clears it. Do not copy the org-role clear onto the ancestor list.
- KTD-2. The ancestor key includes the declared foreign-key value read from the record. Hop identity stays on `base_class.name`. Do not put `polymorphic_name` into that key. The resolver comment at line 428 already separates those two keys.
- KTD-3. Read and write the ancestor-grant boolean only in `scoped_grant?`, after the direct-grant check and after the cascade guard (`return false unless cascade`). A prior cascading check must not satisfy a later `cascade: false` check. Do not memoize the `allow?` or `decide` result. Those methods run the separation-of-duties veto first. A cached allow must not skip that veto. Call `ancestors_for` before any grant-boolean read. Use the stored boolean only on a clean list hit. Otherwise compute it again and overwrite the key. The class, destroyed, and undeclared guards still run before any list-memo read.
- KTD-4. Do not short-circuit hop by hop. A total miss would add an `exists?` per hop, up to `MAX_PARENT_DEPTH`, on the hot deny path. Issue #136 says to measure before that rewrite. This plan's measurement is the pin in R9, not that rewrite.
- KTD-5. Count queries with an `sql.active_record` subscription in the test. The suite has no `assert_queries` helper. Ignore schema and cache notifications. Record the count that `a3d4fef` produces and assert equality in both directions. If the count is not stable across two runs of the same example, stop and report. Do not pick a looser bound. The first check is the pin. The memo must not make that first check cheaper.

### High-Level Technical Design

`ancestors_for` returns the class, destroyed, and undeclared results before it reads `Current`. It consults `Current` before `walk` only after those guards.
The grant boolean is read and written only in `scoped_grant?`, after the direct check and after the cascade guard.
Both hashes are ordinary attributes cleared when `Current` resets.
`scope_for`'s nested SQL is untouched, so a collection page still pays one bounded query shape per subject and permission.

### Assumptions

- `Current` is reset per request and per job, which is why `memoized_org_role` is safe. The new hashes share that lifetime.
- The declared association's foreign key is the value a host assigns when they re-parent a record in memory. Deeper ancestors are not assigned on the child.

### Sequencing

- U1 adds the ancestor-list memo and AE2.
- U2 adds the grant-boolean memo and AE1.
- U3 adds the query pin and the guide note.

### Risks

- A key that omits the foreign key serves a stale parent and can allow the wrong row. AE2 pins both the list and the allow or deny result.
- Caching a `true` for one record under another record's id would be a cross-record allow. The key in R4 includes both ids.
- Lowering the pin in the same commit as the memo would hide a regression in the uncached path. R9 forbids a lower count and a higher count.

### System-Wide Impact

This sits on the allow path.
Fail closed is unchanged only if a cache miss and a cache hit call the same predicate.
The org-role memo clears on role writes. The grant-answer memo clears on R12. The ancestor-list memo does not clear on a grant write. Deeper in-memory parent edits stay the residual in R6.

---

## Implementation Units

### U1. Remember the ancestor list

- **Goal:** A repeated `ancestors_for` for the same record and parent foreign key does not query again. A changed foreign key does.
- **Requirements:** R1, R2, R3, R5, R6
- **Dependencies:** none
- **Files:**
  - `lib/current_scope/parent_chain.rb`
  - `app/models/current_scope/current.rb`
  - `test/parent_chain_test.rb`
- **Approach:** Add a cache hash beside `org_role_cache`. Run the class, destroyed, and undeclared returns before any cache read. Key the rest as in R3. Do not store a record whose id is nil. Store the array `walk` already returns, including an empty array. On a list hit, if any stored ancestor fails `walkable?`, drop the hit, walk again, and do not read the grant-answer memo until that walk finishes. Do not add a query for a delete done through a different object. That case stays the R6 residual. Read the foreign key through the declared reflection so the key cannot drift from `reflection_for`.
- **Patterns to follow:** The hash on `Current` and the `cache.key?` check, so a stored empty array is a hit. Do not store nil for a record whose id is nil. Do not clear this hash on a grant write.
- **Test scenarios:** AE2. A second call with the same foreign key does not issue the walk queries. An empty ancestor list is stored and reused. A class, a destroyed record, and an undeclared model still return an empty list and do not get a stale hit later. Destroy the same parent object and expect a deny. The child id and the child foreign key do not change. The stored grant boolean for that key is overwritten. It is not reused.
- **Verification:** Existing parent-chain examples pass without changed allow or deny expectations.

### U2. Remember the ancestor-grant answer

- **Goal:** A second check of the same subject, permission, and record does not recompute the ancestor grant.
- **Requirements:** R1, R4, R5, R12
- **Dependencies:** U1
- **Files:**
  - `lib/current_scope/resolver.rb`
  - `app/models/current_scope/current.rb`
  - `app/models/current_scope/role.rb` (`reset_cached_permissions`)
  - `app/models/current_scope/role_permission.rb` (`reset_cached_permissions`)
  - `app/models/current_scope/scoped_role_assignment.rb`
  - `test/parent_scope_for_test.rb`
- **Approach:** Inside `scoped_grant?`, after the direct-grant check and after the cascade guard, call `ancestors_for` before any grant-boolean read. Use the stored boolean only on a clean list hit. If the list hit was dropped, or a record guard returned first, compute the boolean from the fresh list and overwrite the key. A destroyed record takes the guard path and must not keep a stored allow. Do not store an `allow?` result. Do not store the `scope_for` relation. Clear that hash from the R12 sites, including rollbacks. Do not clear the ancestor-list memo there. A nil id is a miss every time.
- **Patterns to follow:** U1's cache. `ancestor_scoped_grants` stays the only place that decides the boolean.
- **Test scenarios:** AE1, AE2, and AE3. A deny is cached as a deny and does not become an allow on the second call. A revoke in the same request clears the allow. An unsaved record is not served from the memo. The existing move-parent example in `test/parent_scoped_grant_test.rb` still denies after the parent change. A `full_access` flip and a permission removal each run after a cached ancestor allow and then deny. A revoke inside the open transaction denies. After that revoke rolls back, the next check allows, the same way the org-role memo tests allow after a rolled-back delete. Do not expect a deny after the grant is back. Destroy the child record after a cached ancestor allow and expect a deny. Do not serve the stored boolean. A cascading allow of the bypass permission, followed by `decide` on the four-eyes path, still denies. The cold example around `parent_scoped_grant_test.rb` lines 194 to 208 stays a deny.
- **Verification:** Grant and deny examples already in `test/parent_scope_for_test.rb` stay green.

### U3. Pin the two-hop cost and document the limit

- **Goal:** One two-hop check has a frozen query count, and the guide tells hosts about `includes` and the 100-row limit.
- **Requirements:** R7, R8, R9, R10
- **Dependencies:** U2
- **Files:**
  - `test/parent_scope_for_test.rb`
  - `docs/guides/checking-permissions.md`
- **Approach:** Measure one `allow?` on a two-hop fixture with a subscription. Assert that count. Write the guide note next to the parent-chain section: include the declared parent when loading many children, and expect one walk per distinct record even with this memo.
- **Patterns to follow:** The guide's existing voice. Do not add a gem for query counting.
- **Test scenarios:** The pin asserts equality with the `a3d4fef` count. A lower count fails. A higher count fails. AE3's shape is described in the guide in one sentence.
- **Verification:** The pin passes twice in a row with the same number. The guide names `includes` and the distinct-record limit.

---

## Verification Contract

| Check | Command | Proves |
|---|---|---|
| Chain behavior and pin | `bin/rails test test/parent_chain_test.rb test/parent_scope_for_test.rb test/parent_scoped_grant_test.rb test/resolver_memoization_test.rb` | R1 to R12 |
| Lint | `bin/rubocop` | Style |

One test process per checkout.

## Definition of Done

- Repeated checks of one record in one request do not repeat the ancestor walk.
- A changed parent foreign key does not reuse the old list.
- Allow and deny results are unchanged.
- The two-hop query pin equals the count on `a3d4fef`. A lower count fails. A higher count fails.
- The guide states the 100-record limit and the `includes` hint.
- No CTE and no per-hop `exists?` short-circuit are added.
- Abandoned experiments are not left in the diff.
