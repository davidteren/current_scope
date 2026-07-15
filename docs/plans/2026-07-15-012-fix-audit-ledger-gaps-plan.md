---
title: Audit Ledger Gaps — Bootstrap Grants, Silent Role Replacement, and request_id - Plan
type: fix
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/30
---

# Audit Ledger Gaps — Bootstrap Grants, Silent Role Replacement, and request_id - Plan

## Goal Capsule

- **Objective:** make the audit ledger honest about the one operation it currently misses that matters most — the **bootstrap full-access grant** (`CurrentScope.grant!`, and through it the `current_scope:grant` rake task and `db/seeds.rb`) — by recording it as an append-only event; make the rake task **loud** when it replaces an existing role (a privilege change today printed as a plain success); and populate the `request_id` correlation column that the recorder already stamps but the host context never sets. The docs claim "record **every** authorization change"; today every non-UI grant path records nothing, so the claim is false. Close the gap in code where it is cheap and correct, and scope the claim honestly where code cannot reach.
- **Authority hierarchy:** this plan → the settled v0.1 engine model (`README.md`, `docs/ROADMAP.md`, `STATUS.md`). The following invariants are **immutable** and this change touches **none** of them:
  - Resolver decision order (SoD veto → full_access → org role → scoped role → deny) — untouched; this is a write-path change, not a decision-path change.
  - Fail-closed posture and the `Event.record!` actorless **raise** — preserved. The new actor override is additive: an *explicit non-nil* actor is required to bypass the ambient read; an actorless call with no override still raises exactly as today.
  - One-org-role-per-subject — preserved; `grant!` remains the documented upsert.
  - Resolver **purity** (no writes, no per-decision state) — preserved; the resolver is not modified.
  - Ambient `CurrentAttributes` context — extended by one additive attribute write (`request_id`), no reader override, request/job-scoped as before.
- **Stop conditions — surface rather than guess if:**
  - closing the bootstrap-audit gap would require inventing a fake/sentinel actor that is not a real GlobalID-addressable record (self-attribution to the grantee is the chosen real-record answer — KTD-2; anything else is a fork for the maintainer),
  - the change would cause the **management-UI** grant path to double-record (it already records `org_role.assigned`/`changed`/`removed` with richer detail — the fix must not add a second row), or
  - a proposed "record every path" fix would put an audit write inside a model callback that fires in actorless contexts and reintroduces the raise (KTD-3 rejects the model-callback seam for exactly this reason).

---

## Product Contract

> **Product Contract preservation:** bug + docs fix against filed issue #30; no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Finding verified against gem source in the issue body; this plan does not re-litigate whether the gap is real.

### Summary

Three defects in the audit ledger, all confirmed against source:

1. **Bootstrap grants are invisible.** `CurrentScope.grant!` (`lib/current_scope.rb:142-146`) writes a `RoleAssignment` and calls **no** `Event.record!`. The rake task and `db/seeds.rb` route through it, so the single most security-relevant grant in an app's life — the first full-access Owner — never appears in the ledger, while the initializer comment and README promise "record every authorization change." `Event.record!` (`event.rb:41-45`) **raises** without an ambient actor, which is precisely why an actorless bootstrap context cannot record today.
2. **The rake task silently escalates.** `bin/rails current_scope:grant SUBJECT_ID=2` on a subject who already holds a *limited* role swaps it for full-access Owner and prints a plain `Granted the full-access Owner role…` — a privilege change with no warning and (given defect 1) no ledger row.
3. **`request_id` is always nil.** `Event.record!` stamps `CurrentScope::Current.request_id` (`event.rb:58`), but `Context#set_current_scope_user` (`context.rb:19-26`) never sets it and no doc tells the host to, so every ledger row is uncorrelatable with app logs.

The fix records the bootstrap grant from `grant!` using an explicit self-attributed actor, makes the rake task warn on a role replacement, sets `request_id` from `request.request_id` in the host context hook, and corrects the docs to match the (now-true-by-construction) behavior while documenting the paths that deliberately still do not record.

### Problem Frame

An audit ledger exists to answer "who granted whom what, and when." A ledger that captures every routine UI grant but drops the **first Owner** — the grant that unlocks the entire management surface — fails at its one job for the highest-stakes row. Worse, the docs assert completeness, so an operator relying on the ledger for a security review is actively misled. The rake escalation compounds it: an operator can turn a Member into an Owner from the command line with no warning and no trace. And because `request_id` is never populated, even the rows that *are* recorded can't be tied back to the request that produced them. None of these needs a redesign — they need the recorder called on the bootstrap path, a warning on the rake path, one line in the context hook, and honest docs.

### Requirements

- **R1.** `CurrentScope.grant!` records exactly one append-only audit event per grant that **changes** a subject's org role: `org_role.assigned` when the subject had no prior role, `org_role.changed` (with `from`/`to`) when it replaces a different role. A re-grant of the same role records nothing (idempotent, mirrors the UI no-op rule).
- **R2.** The bootstrap event is attributed to a **real, GlobalID-addressable** actor and carries `details: { source: "bootstrap" }` so it is distinguishable from a UI grant in the ledger.
- **R3.** Recording never requires an ambient controller context: `grant!` supplies the actor explicitly. `Event.record!` gains an optional `actor:` override that, when non-nil, is used instead of the ambient read; when omitted, behavior (including the actorless **raise**) is byte-for-byte unchanged.
- **R4.** The assignment write and its audit event are atomic: a recording failure rolls the assignment back (consistent with the UI transaction and the `:strict` contract). With `config.audit = false`, `grant!` still assigns and records nothing (recorder no-ops).
- **R5.** The `current_scope:grant` rake task prints a distinct **warning** to stderr when the target subject already holds a *different* org role before the grant, naming the old and new role, so a CLI privilege escalation is visible at the console. Exit status is unchanged (success).
- **R6.** `Context#set_current_scope_user` populates `CurrentScope::Current.request_id` from `request.request_id` on every request, so UI and impersonation-boundary events correlate with `ActionDispatch::RequestId` in the host logs. Additive; no other Context behavior changes.
- **R7.** Docs tell the truth: the initializer comment and README stop claiming unqualified "every authorization change," state that the management UI, the impersonation boundary, **and `grant!`/rake/seeds bootstrap** grants are recorded, and explicitly name the paths that deliberately do **not** record (the test helpers `grant_role!`/`grant_scoped_role!`, and direct `RoleAssignment`/`ScopedRoleAssignment` model writes). `grant!`'s upsert/replacement semantics are documented.
- **R8.** Backward compatibility: the only upgrader-visible behavior change is that bootstrap grants now create ledger rows (and, under `config.audit = :strict` on a not-yet-migrated events table, `grant!`/seeds will now raise — the same fail-closed contract that already governs UI mutations). Called out in the upgrading notes.

---

## Key Technical Decisions

- **KTD-1 — Record at `grant!`, the bootstrap convergence point — NOT in a `RoleAssignment` model callback.** The reflex "one guard in the shared function" would put the audit write in `RoleAssignment after_create`, catching every path at once. It is the wrong seam here for two concrete reasons: (a) the **management-UI controller already records** `org_role.assigned`/`changed`/`removed` with richer semantics inside its own bulk transaction — a callback would double-record or force the controller to suppress it; and (b) a callback fires in **actorless** contexts (console, migrations, test seeding) where `Event.record!` raises, turning every stray `RoleAssignment.create!` into a 500. `grant!` is the *documented* bootstrap entry point (rake + seeds + README console recipe all route through it) and the natural, safe place to record. Test-helper and raw model writes stay non-recording by design (documented — R7).
- **KTD-2 — The bootstrap event is self-attributed to the grantee.** A bootstrap grant has no third-party actor — it is the system elevating the first admin. The ledger contract requires actor/subject to be real GlobalID records and reads "subject == actor unless impersonating." Attributing the event to the **grantee** (`actor: subject`, `subject: subject`) is the least-astonishing real-record choice: it reads as "this subject was made an Owner," and `details: { source: "bootstrap" }` disambiguates it from a UI self-grant. A synthetic "system" principal was rejected — there is no GlobalID-addressable system record, and a string sentinel would break GID parse-back on read. (Fork noted in Open Questions.)
- **KTD-3 — `Event.record!` gains an *additive*, non-nil `actor:` override; the actorless raise is preserved.** Signature becomes `record!(event:, target:, details: nil, actor: nil)`. When `actor` is nil (the default, every existing caller), the method reads the ambient actor and raises if absent — **unchanged**. When `actor` is non-nil, it is used and the ambient raise is skipped. This is the minimum change that lets `grant!` record without an ambient context and without weakening fail-closed for any other caller. Does not touch the SoD break-glass Guard recorder (which uses the ambient path).
- **KTD-4 — Reuse existing event names (`org_role.assigned` / `org_role.changed`), don't invent `org_role.bootstrapped`.** Keeps the ledger uniformly queryable — a consumer filtering `org_role.assigned` sees UI *and* bootstrap grants; `details.source` distinguishes origin when needed. (Alternative event name left as an Open Question.)
- **KTD-5 — `grant!` wraps assignment + event in one transaction.** So a recorder failure (e.g. `:strict` on a missing table) rolls the assignment back, matching the UI's all-or-nothing behavior and the documented `:strict` "rolls the mutation back" guarantee. `grant!` currently does a bare `update!`; the transaction is added around it.
- **KTD-6 — `request_id` from `request.request_id`, set in the existing Context before_action.** `ActionDispatch::RequestId` runs on every request and populates `request.request_id`; `set_current_scope_user` already runs there with `request` in scope. One additive line, no new hook, no config. (The recorder already stamps the attribute — this just fills it.)

---

## Implementation Units

### U1. `Event.record!` accepts an explicit actor override

- **Goal:** let a caller supply the actor when there is no ambient context, without weakening the actorless raise for any existing caller.
- **Requirements:** R3.
- **Dependencies:** none.
- **Files:** `app/models/current_scope/event.rb`, `test/audit_strict_test.rb` (or a focused `test/event_record_test.rb` if cleaner — enumerate below).
- **Approach:** change the signature to `record!(event:, target:, details: nil, actor: nil)`. Directionally: `actor ||= CurrentScope::Current.actor`, then keep the existing `if actor.nil? … raise` block. The `subject` derivation stays `CurrentScope::Current.user || actor` — so an explicit override with no ambient user attributes subject to the override actor too (correct for the self-attributed bootstrap, where grantee == both). `request_id` continues to read `CurrentScope::Current.request_id`. No other change to the method body, the `:strict` rescue, or the missing-table handling.
- **Patterns to follow:** the existing keyword-arg signature and the `actor.nil?` guard already in `event.rb:40-45`.
- **Test scenarios:**
  - Explicit `actor:` with **no** ambient actor → records a row attributed to the override; **no raise** (input: `Current.reset`, `record!(event: "x", target: role, actor: user)` → one row, `actor == user.to_gid`).
  - No `actor:` and **no** ambient actor → still raises `ConfigurationError` (regression guard for the fail-closed posture).
  - No `actor:` with an ambient actor → unchanged (reads ambient) — existing behavior, keep an assertion.
  - `config.audit = false` with an explicit `actor:` → returns nil, records nothing.
- **Verification:** the new override records without an ambient context; the actorless-no-override path still raises; existing `audit_strict_test.rb` stays green; RuboCop clean.
- **Execution note:** security-relevant recorder — write the "no override → still raises" test first and watch it stay green as the override is added (it proves the fail-closed path is untouched).

### U2. `grant!` records the bootstrap grant

- **Goal:** record exactly one `org_role.assigned` / `org_role.changed` event when `grant!` changes a subject's org role, self-attributed, atomic, source-tagged — closing the highest-privilege audit gap.
- **Requirements:** R1, R2, R4, R7 (semantics), and KTD-1/2/4/5.
- **Dependencies:** U1.
- **Files:** `lib/current_scope.rb`, `test/grant_test.rb`.
- **Approach:** in `grant!`, resolve the existing assignment's `prior_role` before writing (the row is a `find_or_initialize_by(subject:)`, so read `assignment.role` while it's still the old value). Wrap the `update!` and the recording in a `RoleAssignment.transaction`. After the `update!`, branch exactly as the controller does (KTD-4):
  - `prior_role.nil?` → `Event.record!(event: "org_role.assigned", target: subject, details: { role: role.name, source: "bootstrap" }, actor: subject)`
  - `prior_role.id != role.id` → `Event.record!(event: "org_role.changed", target: subject, details: { from: prior_role.name, to: role.name, source: "bootstrap" }, actor: subject)`
  - same role → no event.
  Directional; the `[assigned | changed | no-op]` decision is the same three-way branch already proven in `role_assignments_controller.rb:85-101` — replicated inline here rather than extracted (the controller's copy is entangled with bulk-transaction counting; a shared helper would couple two paths with different transaction scopes — ponytail: not worth the abstraction for two call sites). Keep `grant!` idempotent and its return value (the assignment) unchanged.
- **Patterns to follow:** `role_assignments_controller.rb#set_org_role` (the assigned/changed/no-op branch and the per-op transaction); the `details:` shape used there.
- **Test scenarios:**
  - **New subject:** `grant!(user)` on a subject with no role → one `org_role.assigned` event, `actor == subject == user`, `details.role == "Owner"`, `details.source == "bootstrap"`; assignment created (existing behavior asserts still pass).
  - **Replacement:** subject holds Member, `grant!(user)` → one `org_role.changed` event with `from: "Member", to: "Owner", source: "bootstrap"`; role upgraded to Owner.
  - **Idempotent re-grant:** `grant!(user)` twice → **one** event total (the second is a same-role no-op — assert `assert_no_difference Event.count` on the second call).
  - **audit off:** `config.audit = false` → assignment made, zero events.
  - **Atomic rollback (:strict, missing table):** with `config.audit = :strict` and the events table absent, `grant!` raises and leaves **no** `RoleAssignment` row (transaction rolled back) — proves R4/KTD-5. (May reuse the missing-table simulation from `audit_strict_test.rb`.)
  - **No ambient context needed:** run `grant!` with `Current.reset` (no controller) → records fine (proves the U1 override path is what unblocks bootstrap).
- **Verification:** all `grant_test.rb` scenarios green; the rake task and `db/seeds.rb` (which call `grant!`) now produce a ledger row with no code change of their own; RuboCop clean.
- **Execution note:** security-relevant grant path — write the "records one event, self-attributed, source=bootstrap" and the ":strict rolls back" tests first.

### U3. Rake task warns on a role replacement

- **Goal:** make a CLI privilege escalation visible — warn when `current_scope:grant` replaces a subject's existing different role.
- **Requirements:** R5.
- **Dependencies:** U2 (the ledger row now also exists; the warning is the human-facing companion).
- **Files:** `lib/tasks/current_scope_tasks.rake`, `test/tasks_test.rb` (new; a lightweight task-invocation test, or extend an existing rake test if one exists — check before adding).
- **Approach:** before calling `grant!`, read the subject's current org role (`RoleAssignment.find_by(subject:)&.role`). If present and not the Owner target, `warn` (stderr) something like `"WARNING: User#2 already held the 'Member' role — replacing it with full-access Owner."` Then proceed with `grant!` and the existing success `puts`. Exit status unchanged. Directional wording; keep it one line, no new abstraction.
- **Patterns to follow:** the existing `abort`/`puts` style in the rake file; `RoleAssignment.find_by(subject:)` lookup used across the engine.
- **Test scenarios:**
  - Subject with a **different** prior role → warning emitted naming old + new role; grant succeeds (exit 0); event is `org_role.changed`.
  - Subject with **no** prior role → no warning; success line only; event is `org_role.assigned`.
  - Subject already **Owner** → no warning (no escalation); idempotent no-op event-wise.
  - Existing rake error paths unchanged: missing `SUBJECT_ID` → abort exit 1; unknown id → `No User with id=…` exit 1 (regression guard — do not disturb).
- **Verification:** warning appears only on a real replacement; existing rake abort/error behavior intact; RuboCop clean.

### U4. Populate `request_id` in the host context hook

- **Goal:** fill the correlation column the recorder already stamps, so ledger rows tie back to `ActionDispatch::RequestId`.
- **Requirements:** R6.
- **Dependencies:** none (independent of U1–U3; can land in any order).
- **Files:** `lib/current_scope/context.rb`, `test/` (a controller/integration test through `test/dummy` asserting the recorded event carries the request's id).
- **Approach:** in `set_current_scope_user`, add one additive line: `CurrentScope::Current.request_id = request.request_id`. `request` is in scope (before_action in a controller); `ActionDispatch::RequestId` runs ahead of app before_actions and guarantees `request.request_id`. No config, no new hook, no reader override. Leaves job/console contexts untouched (they never enter this hook — `request_id` stays nil there, as designed).
- **Patterns to follow:** the existing assignments in `set_current_scope_user` (`Current.user = …`, `Current.actor = …`).
- **Test scenarios:**
  - **Integration (through `test/dummy`):** a UI grant (or any audited action) via a real request records an event whose `request_id` equals the response's `X-Request-Id` / `request.request_id` (non-nil, matches).
  - **Job/console context:** `Event.record!` invoked with no request (e.g. the U2 `grant!` path from a rake context) records with `request_id` nil — proves the field stays host-request-scoped and nothing forces a fake value.
- **Verification:** UI-recorded rows carry the request id; bootstrap/rake rows leave it nil (correctly); RuboCop clean.

### U5. Documentation — honest audit-coverage claim, bootstrap semantics, request_id note

- **Goal:** align the docs with the fixed behavior and stop the false "every change" claim; document what deliberately does not record.
- **Requirements:** R7, R8.
- **Dependencies:** U1–U4 (documents their landed behavior).
- **Files:** `lib/generators/current_scope/install/templates/initializer.rb` (the `config.audit` comment block, line ~56-62), `README.md` (the audit-ledger paragraph ~line 360, and the bootstrap section ~line 117-131), `docs/plans/2026-07-15-009-docs-upgrading-01-02-plan.md`'s target upgrading doc / `STATUS.md` for the behavior-change note (R8).
- **Approach:**
  - Change the initializer `true —` line from "record every authorization change" to a scoped statement: records changes made through the management UI, the impersonation boundary, **and `grant!`/rake/seeds bootstrap grants**; direct model writes and the test helpers are not recorded.
  - In the README audit paragraph, mirror that scoping and add a sentence that the bootstrap grant (`grant!`, `current_scope:grant`, `seed_defaults!`+`grant!`) now appears in the ledger as an `org_role.assigned`/`changed` event tagged `source: "bootstrap"`, self-attributed to the grantee.
  - In the bootstrap section, note `grant!`'s **upsert/replacement** semantics (re-running sets the subject's org role to the target, replacing any existing role) and that the rake task warns when it replaces a different role.
  - Add a one-line `request_id` note: rows carry the host request's `X-Request-Id` for log correlation; nil for grants made outside a request (bootstrap/console).
  - Add the R8 upgrader note: bootstrap grants now create ledger rows, and under `config.audit = :strict` a bootstrap grant on a not-yet-migrated events table now raises (same fail-closed contract as UI mutations) — run migrations before seeding.
- **Test expectation:** none — documentation only; the behavior it describes is covered by U1–U4 tests.
- **Verification:** README + initializer read true against the shipped behavior; the "every change" absolute is gone; the non-recording paths are named; upgrading note present.

---

## Scope Boundaries

**In scope:** the `Event.record!` actor override (U1), recording from `grant!` (U2), the rake replacement warning (U3), `request_id` population in Context (U4), and the docs correction (U5) — engine only.

**Explicit non-goals (preserve deliberate design):**
- **No `RoleAssignment`/`ScopedRoleAssignment` model callback** to "catch every path" — rejected in KTD-1 (double-records the UI, raises in actorless contexts). Direct model writes remain non-recording by design.
- **The test helpers `grant_role!`/`grant_scoped_role!` stay non-recording** — they seed fixtures; emitting audit rows would pollute host test assertions. Documented, not changed.
- **No synthetic "system" actor / no ledger schema change** — self-attribution to the grantee (KTD-2) needs no new column or sentinel identity.
- **No change to the resolver, decision order, or fail-closed raise** — this is a write-path + docs change only.
- **No new `request_id` config or host hook** — one additive line in the existing before_action (KTD-6); the attribute already exists.

**Deferred to Follow-Up Work:**
- Surfacing `source: "bootstrap"` distinctly in the management-UI events index (rows already appear; a filter/badge is cosmetic).
- Hash-chain tamper-evidence for the ledger (already deferred in `event.rb` header).
- A dedicated `org_role.bootstrapped` event name if the maintainer prefers origin-by-name over `details.source` (Open Questions).

---

## Open Questions

- **Bootstrap attribution (KTD-2):** self-attribute the event to the grantee (`actor == subject`), or introduce a documented "system" principal the host can configure (`config.system_actor`)? Self-attribution is chosen as the zero-config, real-GlobalID default; a configurable system actor is a strictly-additive later option if a deployment wants bootstrap grants attributed to an operator account.
- **Event name (KTD-4):** reuse `org_role.assigned`/`changed` with `details.source == "bootstrap"` (chosen — uniform querying), or mint `org_role.bootstrapped`? Decide before first release; the ledger convention favors the reuse.
- **`:strict` + seeds interaction (R8):** confirm the maintainer is comfortable that `grant!` under `config.audit = :strict` now raises on a not-yet-migrated events table (fail-closed, consistent with UI mutations). If a deployment intentionally seeds before migrating audit, they set `config.audit = true` (graceful skip) or `false` for the seed run.

---

## Cross-issue coupling

- **SoD break-glass plan (`docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`):** that feature records `sod.bypassed` via `Event.record!` on the **ambient** actor path. U1's `actor:` override is additive and default-nil, so the break-glass recorder is unaffected — verify the two land without a signature clash (both call `Event.record!` with keyword args; the added `actor:` is optional).
- **Upgrading guide (`docs/plans/2026-07-15-009-docs-upgrading-01-02-plan.md`):** U5's R8 behavior-change note (bootstrap grants now audited; `:strict` now raises on seed against an un-migrated table) belongs in that guide — compose the two so the upgrader note lives in one place rather than duplicated.
- **Config-reference sync (`docs/plans/2026-07-15-010-docs-config-reference-sync-plan.md`):** U5 edits the `config.audit` comment block; coordinate so the config-reference doc and the initializer comment state the same scoped claim.
