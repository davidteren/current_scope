---
title: Delegated Console Controls - Plan
type: feat
date: 2026-09-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/210
---

# Delegated Console Controls - Plan

Issue #210 asks the Members and Subjects pages to show the same management policy the roles index already shows.
The server check stays in charge.
Paths below were read on `origin/main` at `a3d4fef`.

## Goal Capsule

- **Objective:** Disable a Members or Subjects control when the role, the action, and the recipient are already known and `can_manage?` is false, and keep the server as the check that writes.
- **Authority hierarchy:** this plan, then issue #210, then the action table in `docs/guides/configuration-reference.md`, then `AGENTS.md` (stable ids, fail closed).
- **Execution profile:** View changes plus a bulk-apply change that skips refused recipients and names them. No resolver change. No new permission model.
- **Stop conditions:** Do not treat a hidden button as authorization. Do not call `allowed_to?` per row. Do not rename existing element ids. Do not let a mixed selection silently drop people or refuse people the subject is allowed to change.
- **Tail ownership:** Issue #209 already shipped the authorizer. This plan only shows it on the two pages that still ignore it.

---

## Product Contract

### Summary

The roles index asks `CurrentScope.can_manage?` before it offers New, Edit, and Delete.
The Members page and the Subjects page still render Edit, Remove, Revoke, and bulk Set as if every visitor were allowed.
A visitor who submits is refused, but the page told them the control would work.

### Problem Frame

`can_manage?` (`lib/current_scope.rb` line 86) is a predicate.
`authorize_management!` (`app/controllers/current_scope/application_controller.rb` line 28) raises when the predicate is false, and the denial writes no audit event.
`RoleAssignmentsController#create` (`app/controllers/current_scope/role_assignments_controller.rb` lines 37 to 41) asks that predicate for every selected subject before it writes, and one refusal rolls the whole batch back.
That is correct for a batch the subject cannot touch at all.
It is the wrong result for a mixed selection, which issue #210 says must stay usable.
The role on a bulk form is chosen in the browser, so the page cannot know it at render time.

### Requirements

**Known controls**

- R1. On the Members page, Edit permissions follows the roles index: a link when `can_manage?(:update_role, role:)` is true, and plain text plus an explanation when it is false.
- R2. A Members Remove or Revoke control whose assignment, role, and recipient are known is disabled when the matching `can_manage?` call is false. The live Remove on a resolved holder is one of those controls. It is the submit that posts `subject_gid` and a blank `role_id` (`members.html.erb` lines 64 to 68). The role is `@role`. The recipient is the resolved subject. The action is `:revoke_role`. The explanation is in the page, tied to that submit with `aria-describedby`.
- R3. A Subjects scoped-revoke control whose role and recipient are known follows R2.
- R4. Do not rename `org_remove_<id>`, `scoped_revoke_<id>`, or `scoped_chip_revoke_<id>`. `org_remove_<id>` stays the button for a failed gid, an inert row, or a deleted subject (`members.html.erb` lines 71 to 85). The live clear submit has no id today. Add `org_clear_<assignment id>` on that submit. Its explanation id is `org_clear_<assignment id>_limit`. Edit permissions has no id today. The link, and the plain text that replaces it, use `edit_permissions`. The explanation id is `edit_permissions_limit`. Scoped revoke explanations stay `<existing id>_limit`.

**Unknown until submit**

- R5. A control whose role or recipient is chosen in the browser stays submittable. That includes Add org-wide members, Set for selected, the per-row org-role Set, the "+ scoped role" link, and the bulk "Grant scoped role" link. Do not disable every option in a role select.
- R6. The server rechecks every submitted recipient under the existing locks. A direct request that is entirely denied still changes nothing and writes no audit event.

**Mixed selections**

- R7. When a bulk org-role submit contains some recipients the subject may change and some they may not, the allowed recipients change and the notice names the skipped ones.
- R8. The last-holder refusal still applies to the recipients that would actually change. Skipped recipients are not a reason to skip that refusal.
- R9. When every selected recipient is denied, the request changes nothing and writes no audit event.

**Cost and truth**

- R10. The page memoizes `can_manage?` for the same action, role, and target during one render. It does not also call the resolver per row.
- R11. Only a literal `true` from the authorizer enables a known control. R11 does not disable a control R5 leaves submittable. The authorizer stays a pure predicate. When the recipient does not resolve, call `can_manage?` with `target: nil`, and enable that control only on literal true.

### Actors

- A1. A delegated subject who may perform some console actions and not others.
- A2. A full-access subject, who keeps the controls they have today.

### Acceptance Examples

- AE1. Delegated subject opens a role they cannot edit.
  - **Covers:** R1, R4
  - **Given:** `can_manage?(:update_role, role: that role)` is false, and `:access` is allowed.
  - **When:** they open Members.
  - **Then:** `#edit_permissions` is not a link, and `#edit_permissions_limit` is visible.
- AE2. Same subject sees the live Remove on a resolved holder they cannot revoke.
  - **Covers:** R2, R4
  - **Given:** `can_manage?(:revoke_role, role: @role, target: subject)` is false for that resolved holder.
  - **When:** the row renders.
  - **Then:** `#org_clear_<id>` is disabled and described by `#org_clear_<id>_limit`. `#org_remove_<id>` is not that control.
- AE3. Mixed bulk selection.
  - **Covers:** R7, R9
  - **Given:** two subjects are selected, the authorizer allows only one, and the allowed change is not a last-holder removal.
  - **When:** they submit Set for selected.
  - **Then:** the allowed subject changes, the notice names the skipped subject, and events exist only for the allowed subject.
- AE5. Last holder inside a mixed selection.
  - **Covers:** R8
  - **Given:** the only recipient the subject may change is the last live full-access holder, and another selected recipient is denied.
  - **When:** they submit Set for selected.
  - **Then:** the request refuses, neither recipient changes, and no audit event is written.
- AE4. Direct denied post.
  - **Covers:** R6, R9
  - **Given:** the only submitted recipient is denied.
  - **When:** the client posts anyway.
  - **Then:** no assignment changes and no audit event is written.

### Scope Boundaries

- Do not disable every option in a role select. That would call the authorizer once per option per row, which issue #210 forbids.
- Do not add a JSON endpoint so the browser can ask per keystroke.
- Search and pagination stay as they are.
- The denial page for a fully denied direct request stays the existing access-denied response.

### Sources

- `docs/guides/configuration-reference.md` management action table (about lines 180 to 210): `:update_role` and `:destroy_role` take a nil target, `:assign_role` and `:revoke_role` take the org role and the recipient, `:assign_scoped_role` and `:revoke_scoped_role` take the recipient as the target.
- `app/views/current_scope/roles/index.html.erb` lines 7, 19, and 34.
- `app/views/current_scope/roles/members.html.erb` line 9 (Edit permissions), lines 64 to 68 (live clear submit), lines 71 to 85 (`org_remove_<id>`), and line 125 (`scoped_revoke_<id>`).
- `app/views/current_scope/subjects/index.html.erb` line 106.
- `test/system/role_editing_test.rb` lines 35 to 36 for the disabled-control shape.
- `test/integration/subjects_bulk_test.rb`.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. Split controls by whether the triple is known at render. Known triples use R1 to R4. Unknown triples stay submittable under R5, and the server answer is R6 to R9.
- KTD-2. Change `RoleAssignmentsController#create` so a denied recipient is skipped instead of raising inside the batch. Collect the skipped subjects. Write only the allowed ones. If the allowed set is empty, change nothing and take the existing denial path.
- KTD-3. Run `would_remove_last_full_access_holders?` on the allowed set only. A denied recipient must not hide a last-holder refusal, and must not cause one.
- KTD-4. Memoize with a Hash keyed by action, role id or object id, and target identity for the duration of the render. Do not store that hash on `Current`. The host callback may query. The engine adds no query of its own.
- KTD-5. Keep `org_remove_<id>`, `scoped_revoke_<id>`, and `scoped_chip_revoke_<id>`. Renaming them would break `test/integration/role_members_test.rb` and `test/system/members_inert_badge_test.rb`. Add ids only where the control has none today: `org_clear_<assignment id>` on the live clear submit, and `edit_permissions` on Edit permissions. Explanation ids use the `_limit` suffix on those ids.

### High-Level Technical Design

Members and Subjects views call one view helper that memoizes `can_manage?` and returns the enabled flag.
The live clear submit uses `org_clear_<assignment id>`. Known buttons render `disabled: true` and `aria-describedby` when the flag is false, with the explanation element next to them.
The bulk create action partitions recipients after the row locks and before writes.
The notice states who changed and who was skipped.

### Assumptions

- The authorizer is the one shipped for #209. A nil authorizer still means `resolver.full_access?`.
- Scoped revoke on both pages is a known triple. The "+ scoped role" link is not, because the role is chosen on the next screen.
- Partial apply is a behavior change from today's all-or-nothing create. Issue #210's mixed-selection acceptance is the reason. A batch that is entirely denied stays all-or-nothing in the sense that nothing is written.

### Sequencing

- U1 adds the memoized predicate helper and uses it on known Members controls.
- U2 uses it on known Subjects controls.
- U3 changes bulk create to skip denied recipients and names them.
- U4 covers the browser states and the direct denial.

### Risks

- Skipping a recipient after the last-holder check was computed on the full list would refuse a legal change or allow an illegal one. KTD-3 is the pin.
- A disabled button that still submits would look fixed and write anyway. The system test must assert the disabled attribute, not only the hint text.
- Memoizing on `Current` would leak a render answer into a later check in the same request. KTD-4 keeps the hash local.

---

## Implementation Units

### U1. Members page known controls

- **Goal:** Edit permissions, Remove, and Revoke on Members match `can_manage?` when the triple is known.
- **Requirements:** R1, R2, R4, R10, R11
- **Dependencies:** none
- **Files:**
  - `app/views/current_scope/roles/members.html.erb`
  - `app/helpers/current_scope/application_helper.rb`
  - `test/integration/role_members_test.rb`
- **Approach:** Add a render-local memoized wrapper. Use `link_to_if` for Edit permissions. When update is false, `#edit_permissions` is plain text and `#edit_permissions_limit` is the visible hint. On the resolved-holder form, set `id: org_clear_<assignment id>` on the Remove submit. Disable it unless `can_manage?(:revoke_role, role: @role, target: subject)` is literal true, and point `aria-describedby` at `org_clear_<assignment id>_limit`. Leave `org_remove_<id>` and `scoped_revoke_<id>` in place. Disable those known buttons the same way, with their own `_limit` hints. A failed gid, an inert row, or a deleted subject calls `can_manage?` with `target: nil`.
- **Patterns to follow:** `app/views/current_scope/roles/index.html.erb` lines 19 and 34, and the hint id in `test/system/role_editing_test.rb` lines 35 to 37.
- **Test scenarios:** Authorizer false leaves `#org_clear_<id>` disabled and described by `#org_clear_<id>_limit`. Authorizer true leaves that submit enabled. `#org_remove_<id>` is still the inert, deleted, or failed-gid button, and the healthy clear example does not assert it as the live submit. Edit permissions has no `a` when update is false, and `#edit_permissions_limit` is present. The integration example that posts the healthy clear (`role_members_test.rb` around line 382) asserts `#org_clear_<id>`.
- **Verification:** Existing member examples that do not stub the authorizer still find the same ids.

### U2. Subjects page known controls

- **Goal:** Scoped revoke on Subjects follows the same disabled-control shape. Controls with an unknown role stay submittable.
- **Requirements:** R3, R4, R5
- **Dependencies:** U1
- **Files:**
  - `app/views/current_scope/subjects/index.html.erb`
  - `test/integration/subjects_search_test.rb` (only if an assertion reads the revoke control)
- **Approach:** Disable `#scoped_chip_revoke_<id>` when revoke is false for that role and recipient. Add `aria-describedby` in the chip's existing attribute hash. Do not replace that hash and drop `aria-label`. For scoped actions, `target` is the recipient, not the resource. Leave search, bulk Set, per-row Set, "+ scoped role", and "Grant scoped role" submittable. Do not evaluate every option in the role select.
- **Patterns to follow:** U1's hint pattern.
- **Test scenarios:** A denied scoped revoke is disabled and described. The bulk submit control is still present when the authorizer would refuse some roles, because the role is not known yet.
- **Verification:** The Subjects page renders for a full-access subject with the same submit controls as today.

### U3. Mixed bulk apply

- **Goal:** Bulk org-role create applies the allowed subset, names the skipped people, and still refuses a last-holder change.
- **Requirements:** R6, R7, R8, R9
- **Dependencies:** U1
- **Files:**
  - `app/controllers/current_scope/role_assignments_controller.rb`
  - `test/integration/subjects_bulk_test.rb`
- **Approach:** After recipient locks, partition subjects. A recipient is allowed only when every check the current loop would run returns literal true. Check `:revoke_role` when `previous` is present or the submit clears. Check `:assign_role` unless the submit clears. Do not drop the revoke check on a role change. If the allowed list is empty, deny as today, with no writes and no events. Otherwise run the last-holder check on the allowed list only, before any write. A true result uses the existing `refused` flag and `full_access_refusal_alert`, and writes nothing. Do not rescue a non-authorization error into the skip path. Name skipped people with `current_scope_subject_label`. A skipped recipient writes no event.
- **Patterns to follow:** The existing transaction, lock order, and `full_access_refusal_alert`. Do not catch the denial of an empty allowed set inside the transaction and continue. Poisoned-registry tests in `role_members_test` must still refuse a clear and a demote.
- **Test scenarios:** AE3 is the partial apply. AE5 is the last-holder refusal, and neither recipient changes. AE4 is the fully denied post.
- **Verification:** A fully denied batch inserts no `Event`. A mixed batch inserts events only for the allowed recipient.

### U4. Browser coverage

- **Goal:** System tests drive the allowed and denied known controls and the explanation text.
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** U1, U2
- **Files:**
  - `test/system/role_editing_test.rb` or a new `test/system/delegated_console_controls_test.rb`
- **Approach:** Stub `management_authorizer` so `:access` is allowed and `:update_role` and `:revoke_role` are denied. Do not copy the full-access lambda in `role_editing_test.rb` lines 30 to 31 as the deny case. That lambda allows a normal role. Assert the disabled attribute and the hint id on `#org_clear_<id>`, `#edit_permissions_limit`, `#scoped_revoke_<id>`, and `#scoped_chip_revoke_<id>`. Assert that an allowed clear still submits.
- **Patterns to follow:** `assert_selector` on ids, not on CSS structure or visible text alone. The hint text still has to be present for the explanation requirement.
- **Test scenarios:** AE1 and AE2 in the browser. An allowed `#org_clear_<id>` still works. A denied `#org_clear_<id>` does not navigate to a successful notice. Desktop and a narrow viewport both show the hint next to the disabled control.
- **Verification:** `bin/rails test:system` for the new file passes. Desktop and a narrow viewport both show the hint next to the disabled control.

---

## Verification Contract

| Check | Command | Proves |
|---|---|---|
| Server behavior | `bin/rails test test/integration/role_members_test.rb test/integration/subjects_bulk_test.rb test/integration/subjects_search_test.rb test/management_authorizer_test.rb` | R5 to R11 |
| Browser | `bin/rails test:system test/system/delegated_console_controls_test.rb test/system/role_editing_test.rb test/system/members_inert_badge_test.rb` | R1 to R4 |
| Lint | `bin/rubocop` | Style |

One test process per checkout.

## Definition of Done

- The live Members clear submit `#org_clear_<id>` shows a disabled state and an explanation when revoke is false.
- `#org_remove_<id>` is still only the inert, deleted, or failed-gid path.
- Known controls on Members and Subjects show a disabled state and an explanation when `can_manage?` is false.
- Existing control ids are unchanged. `org_clear_<id>` and `edit_permissions` are new because those controls had no id.
- Mixed bulk selection changes the allowed recipients and names the skipped ones.
- A fully denied submit writes no audit event and no assignment change.
- The last-holder rule still refuses the allowed subset when that subset would lock the console.
- The render path does not call the resolver once per row on top of `can_manage?`.
- Abandoned experiments are not left in the diff.
