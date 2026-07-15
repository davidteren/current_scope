---
title: Make the break-glass bypass_sod permission grantable in the role grid - Plan
type: fix
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/21
---

# Make the break-glass `bypass_sod` permission grantable in the role grid

## Goal Capsule

- **Objective:** close the gap between what the docs promise and what the UI delivers for break-glass. The README and `configuration.rb` both say `sod_bypass_permission` (default `bypass_sod`) is "grantable, editable in the role grid — never a hardcoded role." Today it is not: the permission catalog is derived exclusively from routes, `bypass_sod` is not a routed action, so no grid cell for it exists and `Role#permission_keys=` scrubs it. An admin using only the shipped UI cannot build the documented "trusted admin may self-approve" role. Make the virtual bypass permission a first-class, route-adjacent catalog entry so it renders as a grantable cell and survives the save.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). These invariants are **immutable** and this fix touches none of them:
  - resolver decision order: **SoD veto → full_access → org-role → scoped-role → deny**;
  - fail-closed posture;
  - one-org-role-per-subject;
  - resolver **purity** — no writes, no per-decision state (`lib/current_scope/resolver.rb`);
  - ambient `CurrentAttributes` context.
  This is a **catalog/grantability** change, not a decision-path change. The resolver, Guard, and decision order are not edited. When `config.allow_sod_bypass` is off (the default), the catalog is byte-for-byte unchanged.
- **Stop conditions — surface, do not guess, if:**
  - (a) the honest fix would require the catalog to load application models (to discover which types define `current_scope_initiator`) — the catalog must stay route-derived and boot-cheap; if precision seems to demand model introspection, stop and raise the design fork;
  - (b) injecting virtual keys would change any existing catalog key or make `Guard#current_scope_check!`'s `catalog.include?(permission)` gate (`lib/current_scope/guard.rb:41`) raise on a real routed request;
  - (c) the namespaced-resource key drift (see Open Questions) turns out to affect the common non-namespaced case, not just namespaced SoD controllers.

---

## Product Contract

> **Product Contract preservation:** bug fix against a shipped-but-unreachable feature; no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). The break-glass feature itself was specified in `docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`; this plan repairs its management-UI grantability, which that plan assumed (its R2) but did not wire into the catalog.

### Summary

Teach `CurrentScope::PermissionCatalog` about the configured virtual bypass permission. When `config.allow_sod_bypass` is on, for every controller in the route-derived catalog that routes at least one `config.sod_actions` action, inject a synthetic key `"<controller>#<bypass_action>"` (where `bypass_action` is the action segment of `config.sod_bypass_permission`, default `bypass_sod`). Because the catalog is the single source of truth for grantability — the role grid reads `catalog.grouped`, `Role#permission_keys=` filters on `catalog.include?`, and the Guard validates against `catalog.include?` — one injection at that seam makes the permission render as a grid cell **and** survive the role save, with no change to the resolver, the grid class, or the model. Off by default: with `allow_sod_bypass = false`, nothing is injected and the catalog is identical to today.

### Problem Frame

Break-glass is a security workflow whose entire legitimacy rests on being *privilege-gated* (see the 2026-07-12 plan's honest framing: default-off, privilege-gated, always audited). The resolver enforces that gate at `lib/current_scope/resolver.rb:158` by requiring the record's initiator to hold `CurrentScope.permission_key(sod_bypass_permission, record:)` — e.g. `expenses#bypass_sod`. But the only ways to grant that key today are: `full_access` (which grants it implicitly, defeating the point of a *scoped* trusted-approver role), a raw console `CurrentScope::RolePermission` insert, or routing a dummy `bypass_sod` action. The supported surface — the role grid — cannot express it, because:

1. `PermissionCatalog#derive` (`lib/current_scope/permission_catalog.rb:22-31`) emits one key per routed `controller#action`; `bypass_sod` is not routed, so `expenses#bypass_sod` is absent, and `PermissionGrid` renders no cell for it anywhere.
2. `Role#permission_keys=` (`app/models/current_scope/role.rb:31-33`) does `.select { |k| CurrentScope.catalog.include?(k) }`, so even a hand-crafted POST of `expenses#bypass_sod` is silently dropped (this is the companion bug, #20).

So the feature is effectively console-only and the docs' claim (`README.md:304`, `lib/current_scope/configuration.rb:93`) is false. The whole point of promoting break-glass into the engine was "authorization as data you edit in a UI"; an ungrantable privilege breaks that thesis.

### Requirements

- **R1.** With `config.allow_sod_bypass = false` (the default), `CurrentScope.catalog.keys` is byte-for-byte identical to today — no synthetic keys, no new grid columns, existing catalog/grid/role tests unchanged and green.
- **R2.** With `config.allow_sod_bypass = true`, for every non-excluded controller whose route-derived action set intersects `config.sod_actions`, the catalog includes `"<controller>#<bypass_action>"`, where `bypass_action` is the action segment of `config.sod_bypass_permission` (the part after `#` if a full key was configured; the whole value otherwise; default `bypass_sod`).
- **R3.** The injected key resolves and grants like any permission: it appears as its own column in `PermissionGrid` (it is outside `permission_grid_groups`, so it is a leftover single-action column), renders a checkbox on the rows of SoD-routing controllers and a blank cell elsewhere, and `Role#permission_keys=` **keeps** it (no scrub) so a save persists a `RolePermission` row for it.
- **R4.** A role granted `"<controller>#bypass_sod"` through the grid satisfies the resolver's break-glass check for that record type — i.e. the initiator holding this grid-granted permission lifts the veto on a flagged, self-initiated record, with no reliance on `full_access` and no console insert.
- **R5.** No SoD-routing controller is required for injection to be *safe*: when `config.sod_actions` is empty (SoD off) no controller matches, so even `allow_sod_bypass = true` injects nothing. The permission appears only where it can be meaningful.
- **R6.** The `Guard#current_scope_check!` catalog gate (`lib/current_scope/guard.rb:41`) still raises for genuinely-ungrantable routed actions and never spuriously admits one; injected synthetic keys never correspond to a routed request, so they change nothing at the gate.
- **R7.** Docs match behavior: `README.md` and `configuration.rb` state accurately *when* the cell appears (bypass on + controller routes an SoD action), and `CHANGELOG.md` records the fix.

---

## Key Technical Decisions

- **KTD-1 — Fix the catalog seam, not the grid and the model separately.** The catalog is the single definition of "what is grantable"; the grid (`catalog.grouped`), the role setter (`catalog.include?`), and the Guard (`catalog.include?`) all route through it. Injecting the virtual key **once** in `PermissionCatalog#derive` fixes the grid render, the setter scrub (companion #20 for this key), and keeps the Guard consistent — a smaller, less error-prone diff than adding a bespoke "bypass section" to `PermissionGrid` and a special-case exemption to `Role#permission_keys=`. This is the shared-seam fix the issue's own "How" prefers over "document a console workaround."
- **KTD-2 — Inject per controller-that-routes-an-SoD-action, derived from routes + config; never introspect models.** The resolver resolves the bypass key against the record's `model_name.route_key`, which for a conventional resource controller equals the controller name. So the precise, route-derivable set of controllers that could ever need the cell is exactly those whose routed actions intersect `config.sod_actions` (e.g. the controller routing `expenses#approve`). This needs only `Rails.application.routes` and `config.sod_actions` — no loading of application models to test for `current_scope_initiator`, which would be expensive, boot-order-fragile, and against the catalog's "no table to maintain, derived from routes" design. Over-inclusion is fail-safe: a controller that routes an SoD action but whose model exempts itself (nil initiator) gets a grantable-but-never-consulted cell — harmless noise, not a security hole. Under-inclusion, though, is *not* fail-safe and must be stated honestly: when a controller's name differs from the SoD-gated record's `route_key` — e.g. an `approvals` controller routing `approve` on `Invoice` records — U1 injects `approvals#bypass_sod` (a dead cell the resolver never reads, since `permission_key` keys on `record.model_name.route_key`), while the cell the resolver *does* read, `invoices#bypass_sod`, is never injected, so break-glass stays ungrantable for that host and the bug this plan fixes remains. That case is tracked in Open Question #2, whose fix is to key injection off the SoD-gated model's `route_key` rather than the routing controller.
- **KTD-3 — Gate injection on `allow_sod_bypass`, so default-off is a true no-op.** The synthetic key is only ever *consulted* when `allow_sod_bypass` is on (the resolver short-circuits otherwise). Emitting it into the catalog when the feature is off would add meaningless grantable cells and break R1's "byte-for-byte unchanged." So `derive` appends the synthetic keys only when `config.allow_sod_bypass` is true. Additive and reversible: flip the flag off and the catalog reverts.
- **KTD-4 — The injected key is a normal leftover column, not a special UI.** `bypass_sod` is not in `config.permission_grid_groups`, so `PermissionGrid#columns` already renders it as its own single-action column (exactly like `approve`), aligned, blank where not routed. No change to `PermissionGrid` is needed for it to render correctly — only a one-line grid caption tweak so the "derived from routes" hint isn't misleading (U2). This reuses the entire existing grid/expand/round-trip machinery.
- **KTD-5 — Resolver purity and decision order are untouched.** This fix lives entirely in the grantable-set definition (catalog) and its documentation. The resolver's `sod_bypassed?` (`resolver.rb:139-159`) already reads the key correctly; it was simply asking for a key the UI could never grant. No resolver, Guard, or decision-order edit — so none of the immutable invariants are at risk. (Contrast: had we tried to "fix" this by making the resolver treat a missing catalog key as an implicit grant, that would gut fail-closed. Explicitly *not* doing that.)

---

## Implementation Units

### U1. Catalog injects the virtual bypass permission (the shared seam)

- **Goal:** when `allow_sod_bypass` is on, add `"<controller>#<bypass_action>"` to the derived catalog for every non-excluded controller that routes an SoD action; otherwise change nothing.
- **Requirements:** R1, R2, R5.
- **Dependencies:** none.
- **Files:** `lib/current_scope/permission_catalog.rb`, `test/permission_catalog_test.rb`.
- **Approach:** in `derive`, after building the route-derived `routed` keys (current lines 22-31), append synthetic keys when `CurrentScope.config.allow_sod_bypass`. Directionally:
  - `bypass_action = CurrentScope.config.sod_bypass_permission.to_s.split("#").last` — tolerate either a bare action (`"bypass_sod"`) or a full key.
  - Build `grouped_by_controller` from `routed` (`key.split("#") => controller, action`); select controllers whose action set intersects `CurrentScope.config.sod_actions`; for each, add `"#{controller.split('/').last}##{bypass_action}"` — the controller's **last path segment**, not the whole path.

    > **The last segment, not the path — this is the whole fix.** KTD-2 above says the resolver resolves the bypass key against the record's `model_name.route_key`. That is what the resolver will *ask for*, so it is what the catalog must *contain*. Keying off the full controller path injects `admin/reports#bypass_sod` while the resolver looks up `reports#bypass_sod`, which leaves break-glass ungrantable for **every namespaced SoD controller** — the shape most apps approve things in — and hands the admin a grid cell that silently does nothing. Under Rails' resource conventions the last segment *is* the record's route_key, so no model introspection is needed to get this right.
    >
    > *(This sketch originally said `"#{controller}##{bypass_action}"` and was implemented literally. It passed every test, because the dummy app had only a plain `ReportsController` where the two agree. Corrected here after review; `Admin::ReportsController` now exists in `test/dummy` so the gap cannot pass green again. See PR #53.)*
  - Return `(routed + synthetic).uniq.sort` so ordering/dedup match the existing contract (a controller that somehow already routes a real `bypass_sod` action collapses to one key).
  Keep `derive` pure and route/config-only — no model constants, no DB. `keys` stays memoized (`@keys ||= derive`); the engine already calls `CurrentScope.reset_catalog!` on reload/`to_prepare`, and config is read at derive time, so a spec that flips the flag must `reset_catalog!` (mirror however existing catalog tests reset).
- **Patterns to follow:** the existing `filter_map` + `excluded_controllers` guard already in `derive`; the `key.split("#")` idiom used in `grouped`.
- **Test scenarios:**
  - Default (`allow_sod_bypass = false`): `keys` contains no `"*#bypass_sod"`; `keys` equals the pre-change derivation (guard R1) — e.g. `refute keys.any? { |k| k.end_with?("#bypass_sod") }`.
  - Bypass on, `sod_actions = %w[approve]`, `reports` routes `approve` → `assert_includes keys, "reports#bypass_sod"`; `catalog.include?("reports#bypass_sod")` is true; `grouped["reports"]` includes `"bypass_sod"`.
  - Bypass on but `sod_actions = []` → no `"*#bypass_sod"` injected (R5).
  - A non-SoD-routing controller (routes no `sod_actions` action) gets no bypass key even with bypass on.
  - Custom `config.sod_bypass_permission = "override"` → injects `"reports#override"`, not `"reports#bypass_sod"`.
  - Full-key config `config.sod_bypass_permission = "reports#bypass_sod"` → action segment extracted → `"reports#bypass_sod"` (no double-`#`).
  - Excluded controllers still excluded: an excluded controller routing an SoD action gets no bypass key (it never reaches `routed`).
- **Verification:** `test/permission_catalog_test.rb` green including the new cases; the existing three catalog tests unchanged and passing; RuboCop clean.

### U2. Grid round-trip: the cell renders and the role save keeps the key

- **Goal:** prove — and, where a hint misleads, adjust — that the injected key flows through the existing grid and role-setter machinery end to end: a checkbox renders, ticking it POSTs `"<controller>#bypass_sod"`, and `Role#permission_keys=` persists it instead of scrubbing it (companion #20 for this key).
- **Requirements:** R3, and the setter-scrub half of the Problem Frame.
- **Dependencies:** U1.
- **Files:** `app/views/current_scope/roles/edit.html.erb` (one-line caption tweak only), `test/permission_grid_test.rb`, `test/models/role_test.rb`.
- **Approach:** no code change to `PermissionGrid` or `Role` — U1 makes both correct via the catalog. In `edit.html.erb`, the `cs-hint` paragraph (lines 23-27) says columns are "derived from the app's routes"; append a short clause noting a break-glass column may appear when `allow_sod_bypass` is on, so the UI isn't astonishing (Least Astonishment). Add tests:
  - `PermissionGrid`: with bypass on and `reports` routing `approve`, `columns` includes a `"bypass_sod"` leftover column (`group: false`); `cell("reports", <bypass column>, granted)` is a non-blank checkbox with `value == "reports#bypass_sod"` and `name == "role[permission_keys][]"`; `cell(<non-SoD controller>, <bypass column>, granted)` is blank.
  - `Role`: with bypass on, `role.permission_keys = ["reports#bypass_sod"]; role.save!` → `role.grants?("reports#bypass_sod")` is true (the setter keeps it because the catalog now includes it). With bypass **off**, the same assignment is dropped (documents the coupling: grantability follows the catalog, which follows the flag).
- **Patterns to follow:** existing `test/permission_grid_test.rb` cell/column assertions; existing `test/models/role_test.rb` `permission_keys=` scrub tests; the grid-reset pattern used when a test needs the catalog rebuilt.
- **Test scenarios:** enumerated above (grid column present / cell non-blank+correct value / blank elsewhere; setter keeps key when on, drops when off).
- **Verification:** grid + role tests green; the edit view still renders (no ERB error); RuboCop/ERB-lint clean.

### U3. End-to-end: grant `bypass_sod` in the UI, then a bypass actually lifts the veto

- **Goal:** tie the issue's repro to a green test — build the documented "trusted admin may self-approve" role through the role-edit form (no `full_access`, no console insert) and prove the initiator can then perform the SoD action on their own flagged record, with the `sod.bypassed` audit event and header from the existing break-glass path.
- **Requirements:** R4, R6.
- **Dependencies:** U1, U2.
- **Files:** `test/integration/role_grid_test.rb` (or the existing `test/integration/guard_sod_bypass_test.rb` — extend whichever already exercises the dummy SoD controller), reusing `test/dummy` fixtures; no new dummy routes.
- **Approach:** integration-style through `test/dummy`. With `allow_sod_bypass = true` and `sod_actions = %w[approve]`: (1) GET the role edit page and assert the response body **now contains** a `bypass_sod` cell/input for the SoD-routing controller (this is the exact inversion of the issue's confirming assertion — the old `refute_includes body, "bypass_sod"` must become an `assert`); (2) POST the role update granting `"reports#bypass_sod"` (as the grid form would); (3) assign that role to the initiator; (4) drive a flagged, self-initiated `approve` through the gate and assert it is **allowed with reason `:sod_bypassed`**, exactly one `sod.bypassed` event is recorded, and `X-Current-Scope-Reason: sod_bypassed` is set — reusing the guarantees already covered by `test/integration/guard_sod_bypass_test.rb`, here reached purely through a UI-granted permission.
- **Execution note:** security-relevant path — write the failing end-to-end assertion first (the grid page lacking the cell, then the veto still firing because the grant was scrubbed) and watch it go red against `main` before U1 lands, so the test genuinely pins the fix.
- **Patterns to follow:** the existing break-glass integration test's setup (flagged record, initiator holds `bypass_sod`, assert event + header); the management-UI role-update POST shape in `test/integration/role_grid_test.rb` / `management_ui_test.rb`.
- **Test scenarios:**
  - Role-edit GET with bypass on → body includes the `bypass_sod` input for the SoD controller (inverts the issue's `refute`).
  - Grant via POST → `RolePermission` row `"reports#bypass_sod"` exists (not scrubbed).
  - Initiator holding the grid-granted role → flagged self-`approve` allowed, `:sod_bypassed`, one `sod.bypassed` event, header set.
  - Control: same flow with `full_access` role revoked and only the scoped `bypass_sod` grant present still works (proves independence from `full_access`).
  - Negative: bypass off → the grid POST drops the key, the veto stands (`:sod_veto`) — the pre-fix behavior, now explicitly the *flag-off* behavior.
- **Verification:** the new integration assertions green; `test/integration/guard_sod_bypass_test.rb` unchanged and passing; full engine suite green.

### U4. Truth the docs and record the fix

- **Goal:** make `README.md` and `configuration.rb` accurately describe *when* the bypass cell appears, and log the fix.
- **Requirements:** R7.
- **Dependencies:** U1–U3.
- **Files:** `README.md` (break-glass section, around lines 302-325), `lib/current_scope/configuration.rb` (the `sod_bypass_permission` doc comment, lines 91-96), `CHANGELOG.md` (Unreleased → Fixed).
- **Approach:** the existing claim "grantable, editable in the role grid" is now *true*, so keep it but add one clarifying sentence: the bypass permission surfaces as a grid column **only when `config.allow_sod_bypass` is on and a controller routes an SoD action** — so the row for that resource shows a `bypass_sod` checkbox, and granting it to a scoped role is the supported, non-`full_access` way to build the "trusted admin may self-approve" role. Mirror that one-liner in the `configuration.rb` comment. Add a `CHANGELOG.md` "Fixed" entry under `[Unreleased]`: the break-glass `bypass_sod` permission is now grantable through the role grid (previously only reachable via `full_access` or a console insert), plus the note that it appears only when bypass is enabled.
- **Test expectation:** none — documentation only.
- **Verification:** README/comment read true against the shipped behavior; CHANGELOG entry present; no stale "console insert required" caveat remains.

---

## Scope Boundaries

**In scope:** the catalog injection (U1), the grid caption truthing + round-trip tests (U2), the end-to-end UI-grant → veto-lift proof (U3), and doc/changelog truthing (U4) — engine only.

**Out of scope / preserved design choices (do not change):**
- The **route-derived catalog** design itself — the fix *extends* it with config-driven synthetic keys, it does not replace it with a stored permissions table.
- The resolver, Guard, decision order, and resolver purity (KTD-5) — untouched.
- **Opt-in SoD** and **default-off break-glass** — injection is gated on `allow_sod_bypass`; with the feature off, zero change.
- The per-record flag column, its create-time UI, and the enforcement of *who may set the flag* — these remain host concerns per the 2026-07-12 plan's R9.
- The `full_access` implicit-grant path — still grants `bypass_sod`; this fix adds the *scoped* path, it does not remove the org-wide one.

### Deferred to Follow-Up Work

- A dedicated "break-glass / non-routed permissions" visual section or badge in the grid, distinct from ordinary leftover columns. The plain leftover column satisfies "grantable, editable in the role grid" (KTD-4); a distinct treatment is polish, not correctness.
- Namespaced-resource key alignment for the bypass permission (see Open Questions) — treat as a separate hardening issue if a real host runs SoD under a namespaced controller.
- A broader audit of `Role#permission_keys=` silent-drop ergonomics (companion #20) beyond the `bypass_sod` case — if the maintainer wants the setter to *surface* dropped keys rather than silently scrub, that is its own change.

---

## Open Questions

- **Namespaced SoD controllers (key drift).** The resolver resolves the bypass key against the record's `model_name.route_key` (`permission_key` with no `controller_path`), i.e. `"reports#bypass_sod"`. U1 injects one synthetic key per *controller* that routes an SoD action. For a conventional resource controller (`reports`) controller == route_key, so they align. For a **namespaced** SoD controller (`admin/reports#approve`), U1 would inject `"admin/reports#bypass_sod"` while the resolver still checks `"reports#bypass_sod"` — a mismatch, and the same family of drift `test/namespaced_key_drift_test.rb` already tracks for ordinary keys. Decision needed: (a) inject keyed on the record's route_key inferred from the controller (requires a route_key ↔ controller mapping the catalog doesn't currently hold), or (b) inject on both the controller and its route_key, or (c) document namespaced SoD as unsupported for break-glass grantability for now. This plan assumes the common non-namespaced case works and defers (a)/(b)/(c) to the maintainer. **This is the one place the fix could be incomplete for a namespaced host.**
- **Injection scope: SoD-routing controllers vs. all controllers.** KTD-2 injects only where a controller routes an SoD action (precise). If the maintainer prefers the permission be grantable per-record-type regardless of whether the *approve* route lives on the same controller (e.g. approvals handled by a separate `approvals` controller), the injection set may need to key off the SoD-gated **model/route_key** rather than the SoD-routing controller. Confirm the intended granularity.

---

## Cross-issue coupling

- **#21 ↔ #20 (this issue ↔ `permission_keys=` silent drop).** Both are symptoms of the catalog being the single arbiter of grantability. `Role#permission_keys=` scrubbing `expenses#bypass_sod` (#20) is the *reason* a hand-crafted POST can't rescue the missing grid cell (#21). U1's catalog injection fixes **both for the bypass key** in one place: once `catalog.include?("reports#bypass_sod")` is true, the setter keeps it and the grid renders it. If #20 is meant more broadly (the setter should *report* dropped keys instead of silently scrubbing, for any key), that ergonomics change is separate and deferred here — the plans compose cleanly: land this catalog fix first, then #20's setter-ergonomics change (if any) sits on top without conflict. U2's role-setter test documents the shared seam so #20's implementer sees the coupling.
- **Break-glass feature plan (`docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`).** That plan's R2 asserted the bypass permission is "editable in the role grid, never a hardcoded role name" but implemented only the resolver/Guard/config/doc surface — it never wired the catalog, so R2 shipped unmet. This plan is the missing R2 implementation; reference it in the PR so the two read as one feature delivered across two changes.
