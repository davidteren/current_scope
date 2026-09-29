---
title: Validation Follow-ups - Plan
type: fix
date: 2026-09-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/204
---

# Validation Follow-ups - Plan

Issue #204 is the checklist left after the validation pass on PRs #197 to #201.
The P2 items shipped in #202.
These seven items are independent and can land as separate commits.
Paths below were read on `origin/main` at `a3d4fef`.

## Goal Capsule

- **Objective:** Close the seven follow-ups in issue #204 without changing allow or deny results.
- **Authority hierarchy:** this plan, then issue #204, then `docs/reviews/2026-09-04-validation-findings-pr197-201.md`, then `AGENTS.md`.
- **Execution profile:** Seven small units. Each has its own test. None shares a migration.
- **Stop conditions:** Do not auto-revoke a grant the type would now refuse. Do not delete the blank-name guard. Do not drop a matching test table. Do not mark a declaration mismatch as inert.
- **Tail ownership:** Each unit can ship alone. No follow-up issue is required to call this plan done.

---

## Product Contract

### Summary

The review left a badge gap, a guard that looks dead but is not, an untested report branch, two untested boot-message branches, a double audit row, a test-table drift hole, and a docs script that tests cannot load as a file.

### Problem Frame

Operators can see an orphaned grant, and they cannot see a grant that the type's current declaration would refuse.
The report already lists those grants (`grant_refused_by_declaration` at `lib/tasks/current_scope_tasks.rake` line 394).
The console badges only orphaned rows.
The other six items are smaller holes in the same review. They are grouped here so one plan tracks the whole checklist.

### Requirements

**Console label**

- R1. A scoped grant that `grant_refused_by_declaration` would flag shows a badge on the Members page and the Subjects page.
- R2. The badge says the type's declaration would refuse this role if it were granted today, and that the existing grant still matches until someone revokes it.
- R3. The badge is not the inert badge and not a `GrantDiagnosis` verdict. The row is not revoked by rendering it.

**Blank role name**

- R4. `GrantableRoles` still refuses a blank string or symbol name. The guard stays because the method accepts a string as well as a Role. A comment says that. A test pins the blank string.

**Report branch**

- R5. A record-less denial whose stored model name constantizes to something `collection_type?` rejects is counted as unknown and as a dead model when the re-check would otherwise deny. It stays in the ungranted headline count. The test does not ask for it to leave that count. The rake branch is not edited.
- R6. An allow on that row needs no dead-model caveat. That is the current branch. The test pins it.

**Boot message**

- R7. `SchemaGuard.database_context` is tested for a readable database name and for the rescue that keeps the environment and drops the name.
- R8. `SchemaGuard.env_prefix` is tested for an empty string in development and for `RAILS_ENV=<env> ` otherwise.

**One revoke event**

- R9. Destroying one scoped-role row writes one `scoped_role.revoked` event. A second in-memory handle of that same id writes none. A later row with a new id writes its own event on destroy.

**Test tables**

- R10. `SupportTable.prepare` rebuilds when column names, column types, or index names differ. It does not drop a table whose names, types, and index names match. A default id stored as `:primary_key` matches the reflected default. On SQLite that is `:integer`. On MySQL and PostgreSQL that is `:bigint`. That match is not type drift. It never uses `force: true`.

**Docs script**

- R11. The fit chooser script lives in one file under `docs/site/assets/js/`. The comparison page and `test/docs_site_test.rb` both use that file. The README fit section stays derived from the same questions and veto ids.

### Scope Boundaries

- Do not add a new diagnosis symbol to `GrantDiagnosis`. That module's verdicts stay `:no_permissions` and `:unrouted_permissions`.
- Do not change resolver order or the declaration rule itself.
- Do not make the fit chooser a new product. Moving the file is the whole docs unit.

### Sources

- `docs/reviews/2026-09-04-validation-findings-pr197-201.md`.
- `lib/current_scope/grantable_roles.rb` line 186.
- `lib/current_scope/grant_diagnosis.rb`.
- `lib/tasks/current_scope_tasks.rake` lines 349 to 390 and line 394.
- `lib/current_scope/schema_guard.rb` lines 206 to 220.
- `app/models/current_scope/scoped_role_assignment.rb` lines 33 and 232.
- `app/models/concerns/current_scope/audited_writes.rb` `audit_write!` at line 45.
- `test/support/support_table.rb`.
- `test/docs_site_test.rb` and `test/system/docs_site_fit_chooser_test.rb`.
- `docs/site/comparison.md` script starts at line 257.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. Label declaration-refused grants. Do not revoke them in the view. The operator already has a Revoke control on the row.
- KTD-2. Keep `name.present?` in `grantable_roles.rb`. A Role cannot have a blank name. A string argument can. Removing the guard would make a blank string depend on whatever `include?` does with `""`.
- KTD-3. The report branch at lines 355 to 386 is already the product rule. U3 only adds the missing examples.
- KTD-4. `database_context` keeps its rescue. The test feeds a model whose name lookup raises and expects the environment-only string. The diagnostic must not take the guard down.
- KTD-5. Write `scoped_role.revoked` only when this destroy's DELETE changes a row. A second handle deletes zero rows and writes nothing. Do not dedupe by a time window.
- KTD-6. Widen `SupportTable` drift using one normalized token on both sides. Treat a definition type of `:primary_key` as the reflected default id. On SQLite that token is `:integer`. On MySQL and PostgreSQL that token is `:bigint`. Compare that token to the live column's abstract type. Do not compare `type_to_sql(:primary_key)` to the live SQL string or to `type_to_sql` of the reflected type. Other columns compare one abstract type. Do not compare a nil `sql_type` on the definition with a live SQL string. Compare index identity from the block's column and options, using the name `create_table` would assign. Do not compare that pair to `connection.indexes` names directly. Equal schemas still skip the drop. The proof runs in `test/support_tables_test.rb`, which is already outside a transaction.
- KTD-7. Move the script without changing its questions or veto ids. `test/docs_site_test.rb` reads the file instead of slicing a `<script>` out of the markdown. The README derivation keeps using those question and veto strings.

### Sequencing

The units do not depend on each other.
Land them in the order U1 through U7 so the checklist in the issue reads top to bottom.

### Risks

- Calling the new badge "inert" would tell the operator the grant matches nothing. It still matches until revoked. R2 is the pin.
- A second destroy that still runs `after_destroy` after a zero-row DELETE would keep the double event. R9 has to key off the DELETE count, not off the callback running.
- Rebuilding a matching support table reopens the "no such table" race the module comment describes. R10 keeps the no-drop path.

---

## Implementation Units

### U1. Badge declaration-refused grants

- **Goal:** Members and Subjects show R2's badge on a scoped grant the type would now refuse.
- **Requirements:** R1, R2, R3
- **Dependencies:** none
- **Files:**
  - `app/views/current_scope/roles/members.html.erb`
  - `app/views/current_scope/subjects/index.html.erb`
  - `app/helpers/current_scope/application_helper.rb`
  - `app/assets/stylesheets/current_scope/application.css`
  - `test/system/declaration_refused_badge_test.rb` (new)
- **Approach:** Add `current_scope_declaration_refused_badge` beside `current_scope_grant_diagnosis_badge`. Do not add a branch inside the diagnosis helper. Copy the rake lambda's full decision: no badge when the role is nil, the grant is orphaned, the governing class is nil, or the call raises. Load the class with `current_scope_governing_class(inert_on_error: true)`. Return the same `[css_class, short_label, caveat]` triple the diagnosis helper returns. Use a new class `cs-declaration-badge`. Copy the warn outline from `.cs-check-badge`. Do not use the danger fill from `.cs-dead-badge`. Do not use `.cs-badge`. Do not use the ok color token. Put the full R2 sentence in `.cs-badge-note` and in `title`. The visible label is "would refuse". The element id is `declaration_refused_<assignment id>` on both pages. Leave Revoke in place. A row can show this badge and a diagnosis badge together.
- **Patterns to follow:** The orphan badge already on those two views. Stable snake_case ids.
- **Test scenarios:** A grant the declaration refuses shows `#declaration_refused_<id>`, the word "would refuse", and `cs-declaration-badge` on Members and on Subjects, and the row is not revoked. An orphan shows no declaration badge. A nil role, a nil class, and a rescued lookup show no badge and do not raise. A conforming grant shows no declaration badge. A row that is both a diagnosis finding and a declaration refusal shows both badges.
- **Verification:** The system test visits Members and Subjects, finds `#declaration_refused_<id>`, and finds the revoke control on that same grant.

### U2. Pin the blank-name guard

- **Goal:** A blank string role name is refused, and the comment says why the guard exists.
- **Requirements:** R4
- **Dependencies:** none
- **Files:**
  - `lib/current_scope/grantable_roles.rb`
  - `test/grantable_roles_test.rb`
- **Approach:** Add one comment on the `name.present?` line: the Role form cannot be blank, the string form can. Stub the allow-list reader so the list contains `""` without going through the setter. Assert `current_scope_grants_role?("")` is false. That example goes red if `present?` is removed. Do not delete the condition.
- **Patterns to follow:** The comment above the method that already explains the nil-list case.
- **Test scenarios:** `""` is refused. A real role name on the allow list is still accepted. A Role instance is unchanged.
- **Verification:** The stubbed blank allow-list example fails if `present?` is removed. A normal allow list that does not contain `""` is not that pin.

### U3. Pin the dead model-name branch

- **Goal:** The `collection_type?` failure path is covered for both a deny and an allow.
- **Requirements:** R5, R6
- **Dependencies:** none
- **Files:**
  - `test/report_task_test.rb`
- **Approach:** Write a record-less denial whose model name constantizes to a non-collection. Assert the unknown text and the dead-model text. Assert `allow?` is called with `model: nil`. Assert the row stays in the ungranted count. Do not assert that it is absent from that count. Assert an allow case does not gain the dead-model caveat. Do not edit the rake branch.
- **Patterns to follow:** The comment at `current_scope_tasks.rake` lines 372 to 376. Do not change the branch.
- **Test scenarios:** R5 and R6 as two examples. R5 expects the row in the ungranted count and in the dead-model text. A name that does not constantize stays unknown. Do not weaken that example. If R5 fails because the branch was edited, restore the branch. Do not edit the branch to make a new absence assertion pass.
- **Verification:** Both examples pass against the current branch with no production edit. If R5 fails, the branch has drifted and the implementer stops before "fixing" the test.

### U4. Test the schema-guard strings

- **Goal:** Both `database_context` branches and both `env_prefix` branches have examples.
- **Requirements:** R7, R8
- **Dependencies:** none
- **Files:**
  - `test/schema_guard_test.rb` (new)
- **Approach:** Assert the success string includes `Rails.env` and the inspected database name. Stub the name lookup to raise and assert the string is `the <env> database` with no name. Assert `env_prefix` in development and in test.
- **Patterns to follow:** The rescue comment at lines 210 to 213. Keep `connection_pool`, not `connection`.
- **Test scenarios:** R7's two strings. R8's two prefixes, including the trailing space on the non-development prefix.
- **Verification:** The examples fail if the rescue drops the environment or if development prints `RAILS_ENV=development`.

### U5. One revoke event per row

- **Goal:** Two handles destroying one scoped-role row produce one ledger event.
- **Requirements:** R9
- **Dependencies:** none
- **Files:**
  - `app/models/current_scope/scoped_role_assignment.rb`
  - `test/models/scoped_role_assignment_test.rb`
- **Approach:** In the revoke callback, write the event only when this destroy's DELETE changed a row. Rails sets `_trigger_destroy_callback` from that count before the callback. Key off that flag. Do not count table rows after the first destroy, because the row is already gone. Do not move the write to `after_commit`. Strict audit must roll the grant back with the event. A recreated row has a new id and still audits. Leave the granted callback alone.
- **Patterns to follow:** `record_scoped_role_audit` already returns when `config.audit` is off. Keep that guard first.
- **Test scenarios:** Two in-memory objects with the same id: one `scoped_role.revoked` row. Destroy after recreate: a second event. Audit off: zero events.
- **Verification:** The event count is 1 for the double handle, not 0 and not 2.

### U6. Widen support-table drift

- **Goal:** A type or index change rebuilds the test table. A matching table is not dropped.
- **Requirements:** R10
- **Dependencies:** none
- **Files:**
  - `test/support/support_table.rb`
  - `test/support_tables_test.rb`
- **Approach:** Compare one normalized type token on both sides, as KTD-6 says. Compare index identity from the block, including a block that declares an index. Drop only on mismatch, then `create_table` with `if_not_exists: true`. Add the examples to `test/support_tables_test.rb`. Never pass `force: true`.
- **Patterns to follow:** The comment at the top of `support_table.rb`. Update the ponytail line so it no longer says types and indexes are invisible.
- **Test scenarios:** Change a column type and expect the new type after `prepare`. The no-drop example uses a default id, the same call shape as `IdentityUser`, plus an index. It does not pass `id: :string`. A string id can match on both sides while `IdentityUser` still drops. Change an index and expect a rebuild.
- **Verification:** The matching case does not call `drop_table`. The example is safe on SQLite, MySQL, and PostgreSQL because it runs outside a transaction.

### U7. Load the fit chooser from one file

- **Goal:** The page, the unit test, and the README derivation share one script file.
- **Requirements:** R11
- **Dependencies:** none
- **Files:**
  - `docs/site/assets/js/` (new file for the script that starts at `docs/site/comparison.md` line 257)
  - `docs/site/comparison.md`
  - `test/docs_site_test.rb`
  - `test/system/docs_site_fit_chooser_test.rb`
- **Approach:** Move the script unchanged into `docs/site/assets/js/`. In the page, load it with `<script src="{{ '/assets/js/<file>.js' | relative_url }}"></script>` so the site `baseurl` is honored. Point the question and veto scan at that file. Change the system test so it reads the file and inlines it, because an external script tag has an empty body. Keep the README check that compares those strings to the README fit section. Do not change questions or veto ids.
- **Patterns to follow:** The existing scan of `q: "` and `veto: "` in `test/docs_site_test.rb`. Do not re-pin indentation.
- **Test scenarios:** The question count and veto ids stay the ones the README test already expects. The system test still drives the chooser.
- **Verification:** `test/docs_site_test.rb` passes, and the markdown file no longer contains the inline script body.

---

## Verification Contract

| Check | Command | Proves |
|---|---|---|
| Unit and integration | `bin/rails test test/report_task_test.rb test/docs_site_test.rb` plus the grantable, schema-guard, audit, and support-table files touched | R4 to R11 |
| Browser | `bin/rails test:system test/system/declaration_refused_badge_test.rb test/system/docs_site_fit_chooser_test.rb` | R1, R2, R11 |
| Lint | `bin/rubocop` | Style |

One test process per checkout. U6 must not run beside a second suite.

## Definition of Done

- All seven requirements groups have a failing-before pin or a browser assertion.
- No grant is revoked by the new badge.
- The blank-name guard is still present and tested.
- A second destroy handle does not write a second revoke event.
- A matching support table is not dropped.
- The fit chooser script has one source file.
- Abandoned experiments are not left in the diff.
