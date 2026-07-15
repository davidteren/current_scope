---
title: Role#permission_keys= silently drops unknown keys — make the rejection loud - Plan
type: fix
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/20
---

# Role#permission_keys= silently drops unknown keys — make the rejection loud

## Goal Capsule

- **Objective:** stop `CurrentScope::Role#permission_keys=` from silently discarding permission keys that aren't in the route-derived catalog. A typo (`reports#aprove`) or a programmatic grant of an unrouted key (including the break-glass `bypass_sod`) currently vanishes with no error, no log, and a clean save — producing a role that looks correct and fails closed at runtime. Make the rejection **loud by Rails convention** (a validation error on save) while preserving the *deliberate* stale-key scrub behavior behind an explicit opt-in.
- **Authority hierarchy:** this plan → the settled v0.1 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). Immutable invariants preserved verbatim by this change:
  - Resolver decision order (SoD veto → full_access → org role → scoped role → deny) — **untouched**; this fix lives entirely in the `Role` model's write path, not the resolver.
  - Fail-closed posture — **strengthened, not weakened**: today a dropped grant already fails closed (lockout, not escalation); this fix makes the *cause* visible at write time instead of at the 403.
  - One-org-role-per-subject — unaffected.
  - Resolver **purity** (no writes, no per-decision state) — unaffected; no resolver code changes.
  - Ambient `CurrentAttributes` context — unaffected.
  - Route-derived catalog is a **deliberate design choice** and stays: the fix does not add a permissions table or let arbitrary keys persist. It changes only how *unknown* keys are *signalled* (error vs. silence).
- **Stop conditions — surface rather than guess if:**
  1. the honest fix would require persisting a key that is not in the catalog (it must not — persistence stays catalog-filtered; only the *signal* changes);
  2. making the setter strict would break the management UI's normal save path (it must not — the grid only ever submits catalog keys; verify, don't assume);
  3. the escape hatch for the stale-key cleanup case cannot be expressed without a second, mass-assignable writer that re-opens the silent-drop hole.

---

## Product Contract

> New bug fix, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Frame and evidence come from issue #20, confirmed against source before planning.

### Summary

`Role#permission_keys=` (`app/models/current_scope/role.rb:32`) stages a replacement permission set via `Array(keys).uniq.select { |k| CurrentScope.catalog.include?(k) }`. The `.select` silently drops every key not currently in the route-derived catalog. This is intentional for scrubbing stale keys left behind when a controller is removed — but on a **security-grant API** it means typos and programmatic grants disappear with zero signal. The save succeeds, the role reloads without the key, and the user is later denied with an unexplained 403. Because `bypass_sod` (the configurable `sod_bypass_permission`) is *never* a routed action, it is *always* dropped — so a `db/seeds.rb` that grants break-glass looks correct, saves cleanly, and produces a role that can never bypass.

The fix keeps the route-derived catalog and keeps stale-key scrubbing available, but flips the **default** for unknown keys from *silent drop* to *loud validation error*, and exposes what was rejected. Scrubbing becomes an explicit, named opt-in.

### Problem Frame

An authorization library's cardinal rule (stated in `lib/current_scope.rb:29`) is that it "must never turn a configuration mistake into a silent allow or an undiagnosable deny." The current setter violates the second half: a mistyped or unrouted grant becomes an *undiagnosable deny*. The blast radius is widest exactly where it hurts most — bootstrap/seed code granting security permissions, run once, unattended, with no human watching the console echo a scrubbed array. The intent to scrub is documented only in an inline comment (`role.rb:28-30`); nothing at the call site tells the operator a key was thrown away.

### Requirements

- **R1.** Assigning `permission_keys` a set containing one or more keys that are neither blank nor in the catalog makes the record **invalid**: `save` returns `false` and `save!`/`update!` raises `ActiveRecord::RecordInvalid`. The validation message names the rejected keys.
- **R2.** Blank/empty string entries (form-array padding) are **not** errors — they are dropped silently, as today. Only non-blank, non-catalog keys trip the validation.
- **R3.** No unknown key is ever **persisted**. Persistence stays catalog-filtered; R1 changes the *signal on the strict path*, not what can reach `role_permissions`.
- **R4.** An explicit, named opt-in preserves the deliberate stale-key scrub: a caller can assign a set and have non-catalog keys dropped silently and legitimately (the removed-controller cleanup case), without going through the mass-assignable `permission_keys=` writer.
- **R5.** The keys that were dropped/rejected on a save are observable programmatically (extend the existing `permission_keys_change` diff so callers — and the engine's own audit recorder — can see them), so a scrubbing caller that *wants* silence can still log if it chooses.
- **R6.** The management UI's normal role-save path is **unchanged in behavior**: submitting the grid (which only ever emits catalog keys) never trips the new validation, and editing a role that holds a now-stale key still drops that stale key transparently on save.
- **R7.** Backward-compatibility note is shipped: this is a **behavior change** for programmatic callers that previously relied on silent drop of *non-stale* keys. Upgraders who assign literal sets containing stale keys must switch those call sites to the explicit scrub opt-in (R4). Documented in CHANGELOG with the migration.

---

## Key Technical Decisions

- **KTD-1 — Strict-by-default is a *validation error*, not a raise-on-assignment.** The Rails-idiomatic, least-astonishing signal for "this input was rejected" is a validation failure at save time, not an exception thrown from an attribute writer. `role.permission_keys = [...]` must not raise — assignment stages; `save`/`save!` adjudicates. This keeps `permission_keys=` usable in the same mass-assignment flows as today (`update!(permission_keys: …)`, strong-params) and makes the failure surface exactly where operators already look (`RecordInvalid`, `errors[:permission_keys]`). **Chosen over** raise-on-assignment (astonishing, breaks `update` returning false) and over log-only (a warning in a seed run is still easy to miss; the issue's own "at minimum" floor — we do better than the floor).
- **KTD-2 — Stage keys *raw*; validate against the catalog; filter only at persist.** Today the setter scrubs at assignment, so validation can't see what was dropped. Move the scrub out of the setter: stage `Array(keys).map(&:to_s).reject(&:blank?).uniq` (raw, minus blank padding per R2), add a `validate` that flags non-catalog entries, and keep `persist_permission_keys` filtering to the catalog at `insert_all` time (defense-in-depth — nothing unknown reaches the table even if a future code path bypasses validation). One behavior seam, three cooperating pieces, no new persistence surface.
- **KTD-3 — The escape hatch is a named method, not a setter kwarg or a stateful flag.** A Ruby attribute writer can't take keyword args, and a `scrub_unknown = true` boolean attribute is stateful and astonishing (order-dependent with the assignment). Add `assign_permission_keys(keys, scrub: false)`; `permission_keys=` delegates to it with `scrub: false` (strict). Scrub callers write `role.assign_permission_keys(keys, scrub: true)`. One implementation, the setter stays the strict mass-assignment writer, and scrubbing is opt-in and self-documenting at the call site. **This is the design fork the issue names ("strict default + `scrub: true` escape hatch"); picked over exposing scrub through the mass-assignable writer, which would re-open the silent hole for form params.**
- **KTD-4 — No resolver, Guard, or catalog changes.** The root cause is one line in one model method that every write path already routes through (mass-assignment, `update!`, the controller, seeds). Fixing it there fixes every caller at once — a smaller, safer diff than touching the shared resolver/catalog, and it leaves the catalog's route-derivation (a deliberate design choice) intact. No security invariant is weakened; the veto, decision order, and fail-closed posture are byte-for-byte unchanged.
- **KTD-5 — `bypass_sod` grantability is explicitly out of scope here (see Cross-issue coupling).** After this fix, granting the never-routed `sod_bypass_permission` raises a *clear validation error* instead of vanishing silently. That is a strict improvement (loud, not silent) but it does **not** make break-glass grantable — that's companion issue #21. This plan deliberately does not add `bypass_sod` to the catalog; doing so is #21's decision and would couple two changes that should ship independently.

---

## Implementation Units

### U1. Strict validation: unknown permission keys make the role invalid

- **Goal:** flip the default for non-catalog keys from silent drop to a loud validation error, while keeping blanks harmless and persistence catalog-filtered.
- **Requirements:** R1, R2, R3.
- **Dependencies:** none.
- **Files:** `app/models/current_scope/role.rb`, `test/models/role_test.rb`.
- **Approach:**
  - Split the setter from the scrub. `permission_keys=` stages **raw**: `@pending_permission_keys = Array(keys).map(&:to_s).reject(&:blank?).uniq` (R2 drops blank form padding; no catalog `.select` here anymore).
  - Add `validate :permission_keys_in_catalog`. It runs only when a grid was staged (`@pending_permission_keys` present) and not in scrub mode (see U2): compute `unknown = @pending_permission_keys.reject { |k| CurrentScope.catalog.include?(k) }`; if any, `errors.add(:permission_keys, "not in the permission catalog: #{unknown.join(', ')} — check for typos, or use assign_permission_keys(..., scrub: true) to drop stale keys deliberately")`.
  - Keep `persist_permission_keys` filtering at insert: `staged = @pending_permission_keys.select { |k| CurrentScope.catalog.include?(k) }` before `insert_all` (R3 defense-in-depth — on the strict path this is a no-op because validation already guaranteed all-catalog; on the scrub path U2 relies on it).
  - Reader `permission_keys` still returns `@pending_permission_keys || role_permissions.pluck(:permission_key)` — now returns the *raw* staged set pre-save (honest: shows what was assigned, including the about-to-be-rejected keys).
- **Patterns to follow:** the existing `validates :name, …` style in `role.rb`; the "fail loud on wiring mistakes" doctrine in `lib/current_scope.rb:29`; the `after_save`/`@pending_permission_keys` staging already in the file.
- **Execution note (security-relevant write path):** test-first. Write the "typo makes the role invalid" and "blank is harmless" tests, watch them go red against the current silent-drop code, then edit `role.rb`.
- **Test scenarios:**
  - Typo path: `role.permission_keys = %w[reports#aprove reports#approve]`; `assert_not role.save`; `assert_includes role.errors[:permission_keys].first, "reports#aprove"`; catalog key not persisted because the save failed.
  - `save!` raises: `assert_raises(ActiveRecord::RecordInvalid) { role.update!(permission_keys: %w[legacy#does_not_exist]) }`.
  - Blank harmless (R2): `role.permission_keys = ["", "reports#index"]`; `assert role.save`; `assert_equal %w[reports#index], role.reload.permission_keys`.
  - All-valid persists unchanged: `role.permission_keys = %w[reports#index reports#approve]` saves and reloads with both keys.
  - Failed save leaves prior set intact (adapt the existing test): a role holding `reports#index` that is updated with a bogus key keeps `reports#index` on reload.
  - Persistence never holds an unknown key (R3): after any successful save, `role_permissions.pluck(:permission_key)` ⊆ catalog.
- **Verification:** the flipped `role_test.rb` is green; the *old* silent-drop test (`"permission_keys persist on save, filtered to the catalog"`) is rewritten to assert the new strict behavior (this test **must** change — its old assertion is the bug); full model suite green; RuboCop clean.

### U2. Explicit scrub opt-in + rejected-keys observability

- **Goal:** preserve the deliberate stale-key cleanup as a named, opt-in call, and expose what was dropped/rejected on the change diff.
- **Requirements:** R4, R5.
- **Dependencies:** U1.
- **Files:** `app/models/current_scope/role.rb`, `test/models/role_test.rb`.
- **Approach:**
  - Add `assign_permission_keys(keys, scrub: false)`: stages the raw set (same normalization as U1) and records the scrub intent on a transient `@scrub_permission_keys` ivar consulted by U1's validation (when `scrub: true`, the `permission_keys_in_catalog` validation is skipped, so non-catalog keys pass validation and get filtered out at `persist_permission_keys`). Reset the ivar in `reload` and after persist alongside `@pending_permission_keys`.
  - `permission_keys=` becomes a thin delegate: `assign_permission_keys(keys, scrub: false)`. (Mass-assignment / strong-params always hit the strict path — R4's guarantee that the escape hatch can't leak through form params.)
  - Extend `@permission_keys_change` in `persist_permission_keys` to add a `:rejected` (or `:dropped`) array = staged-raw minus catalog-filtered, so a scrubbing caller (or the controller's audit recorder) can see and log what was scrubbed (R5). `added`/`removed` continue to be computed against the *filtered* staged set (what actually persisted), so existing consumers (`roles_controller.rb:107`) are unchanged.
  - `ponytail:` comment on the scrub path naming why it exists (removed-controller cleanup) and that it is the *only* sanctioned silent-drop.
- **Patterns to follow:** the existing `attr_reader :permission_keys_change` diff contract and its `{ added:, removed: }` shape; the `reload(...)` ivar-reset pattern already in the file.
- **Test scenarios:**
  - Scrub opt-in drops silently: `role.assign_permission_keys(%w[legacy#stats legacy#gone], scrub: true)` where only `legacy#stats` is routed → `assert role.save`; reload has `%w[legacy#stats]`; `role.permission_keys_change[:rejected]` includes `legacy#gone`.
  - Scrub does **not** leak through mass assignment: `role.update(permission_keys: %w[legacy#gone])` (no scrub) is invalid (proves R4 — form params can't reach the hatch).
  - Rejected diff on a scrub save lists exactly the non-catalog keys; `added`/`removed` reflect only persisted keys.
  - `reload` clears staged + scrub state (a subsequent `permission_keys` reads from the table).
- **Verification:** scrub tests green; the mass-assignment strict guarantee proven by the "scrub can't leak" test; RuboCop clean.

### U3. Management-UI regression proof (grid save + stale-key edit)

- **Goal:** prove the strict default does not disturb the engine's own role editor — the highest-traffic caller of `permission_keys=`.
- **Requirements:** R6.
- **Dependencies:** U1, U2.
- **Files:** `test/integration/role_grid_test.rb` (extend; existing), optionally `test/system/role_editing_test.rb` if a browser-level assertion is warranted.
- **Approach:** no production code change expected here — this unit is the guardrail that confirms KTD-4's claim. Assert that (a) a normal grid submit through `RolesController#update` (catalog keys + expanded group tokens via `PermissionGrid#expand`, which only yields routed keys) saves successfully and records the `role.updated`/`role.renamed` event as before; (b) editing a role that holds a stale key (a `role_permissions` row whose controller no longer routes) and re-saving the grid drops the stale key transparently — because the grid never round-trips a row for an unrouted controller, the submitted set is all-catalog and validation passes. If any assertion fails, the strict validation is too broad and must be narrowed before merge (stop condition 2).
- **Patterns to follow:** the existing `role_grid_test.rb` / `management_ui_test.rb` request-style tests through `test/dummy`; `PermissionGrid#expand` semantics (`permission_grid.rb:65`).
- **Test scenarios:**
  - Grid save happy path: post a valid grid (group tokens + raw keys) → `assert_redirected_to`; role has the expected catalog keys; one audit event recorded.
  - Stale-key transparent cleanup: seed a role with a `role_permissions` row for an unrouted `gone#index`; edit + save the grid without touching other cells → save succeeds; `gone#index` is gone; no validation error surfaced to the operator.
  - Partial-group round-trip still works (the escalation guard in `permission_grid.rb:45-61` preserves existing keys via hidden inputs, all of which are catalog keys) → save valid.
- **Verification:** integration suite green; UI save path demonstrably unaffected; no new flash/error rendered on a normal save.

### U4. Docs + CHANGELOG (behavior-change note and the scrub recipe)

- **Goal:** document the loud-by-default behavior, the scrub opt-in, and the upgrade note.
- **Requirements:** R7.
- **Dependencies:** U1–U3.
- **Files:** `README.md` (roles / permission-grid section), `CHANGELOG.md`, `docs/ROADMAP.md`/`STATUS.md` if it tracks fixes.
- **Approach:** add a short subsection: assigning `permission_keys` with a key that isn't in the route-derived catalog now makes the role invalid (names the rejected keys) instead of silently dropping it; to deliberately scrub stale keys from removed controllers, call `role.assign_permission_keys(keys, scrub: true)`. CHANGELOG entry under a **behavior change** heading with the one-line migration (seed/bootstrap code that assigned literal sets containing stale keys must add `scrub: true`). Do **not** touch the `sod_bypass_permission` "grantable, editable in the role grid" claim near `README.md:~301` — that claim is addressed by #21 (see coupling); note only that granting an unrouted permission now errors loudly.
- **Test expectation:** none — documentation only.
- **Verification:** README renders; CHANGELOG has the behavior-change + migration line; the scrub recipe is copy-able and correct against the U2 API.

---

## Scope Boundaries

**In scope:** the `Role#permission_keys=` strict-by-default validation, the `assign_permission_keys(…, scrub:)` opt-in, the extended `permission_keys_change` diff, UI regression proof, and docs/CHANGELOG. Model layer + tests + docs only.

**Preserved deliberate design choices (NOT changed):** the route-derived catalog (no permissions table); catalog-filtered persistence; the resolver, decision order, and fail-closed posture; opt-in SoD. This fix changes only the *signal* for unknown keys, never what may persist.

### Deferred to Follow-Up Work

- Making `sod_bypass_permission` (`bypass_sod`) actually grantable — companion issue **#21** (see coupling). This plan makes its current ungrantability *loud*; #21 makes it grantable.
- A management-UI affordance to surface `permission_keys_change[:rejected]` as a flash (the UI never trips it today, so there's nothing to surface yet — add if #21 introduces grantable non-route keys entered by hand).
- Correcting the README `bypass_sod` "grantable, editable in the role grid" claim — owned by #21, which is what will make the claim true.

**Explicit non-goals:** no resolver/Guard/catalog changes; no new config; no change to how the grid derives columns.

---

## Open Questions

- **Grantable-set seam for #21.** U1's validation checks `CurrentScope.catalog.include?(k)` directly. #21 will need `sod_bypass_permission` to be grantable, i.e. it must extend "what is grantable" beyond pure route derivation. Should this plan route the membership test through a one-line predicate (e.g. `CurrentScope.grantable?(key)`, defaulting to `catalog.include?`) so #21 has a clean hook — or keep the direct catalog call and let #21 refactor it? Ponytail default: **keep the direct call** (don't build #21's seam speculatively), and let #21 introduce the predicate when it actually needs it. Flagging in case the maintainer wants the seam pre-placed to avoid a second touch of `role.rb`.
- **`:rejected` vs `:dropped` key name** on `permission_keys_change`. Assumed `:rejected`. Adjust if a different taxonomy is preferred before first consumer depends on it.
- **Error-message ergonomics.** The proposed message names the offending keys and points at `scrub: true`. Confirm that's the desired tone for a seed-time `RecordInvalid` (vs. a terser message) — this is the operator's primary diagnostic.

---

## Cross-issue coupling

- **#20 ↔ #21 (this issue ↔ `bypass_sod` ungrantable).** These are two halves of one story and should compose, shipping in order **#20 then #21**:
  - **#20 (this plan)** makes the silent drop *loud*: after it, assigning the never-routed `bypass_sod` raises a clear `RecordInvalid` naming the key, instead of vanishing. That converts an *undiagnosable deny* into a *diagnosable rejection at write time* — but break-glass is still not grantable.
  - **#21** makes `sod_bypass_permission` actually grantable (by extending the grantable set — most cleanly via the `CurrentScope.grantable?` predicate named in Open Questions, or by folding the configured bypass permission into the catalog). Once #21 lands, U1's validation should accept it, and the `README.md:~301` "grantable, editable in the role grid" claim (which #20 deliberately leaves alone) becomes true and is corrected there.
  - **Composition rule:** #21's plan should treat U1's catalog check as its extension point. If #21 chooses the predicate seam, it edits the single line U1 introduced; if it folds bypass into the catalog, no `role.rb` change is needed and U1's validation passes automatically. Either way, #20 must not pre-decide #21's mechanism — it only guarantees the loud signal that makes #21's gap visible.
