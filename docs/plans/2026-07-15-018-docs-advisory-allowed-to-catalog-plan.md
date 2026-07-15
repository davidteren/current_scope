---
title: Advisory allowed_to? Never Consults the Catalog — Document the Asymmetry - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/36
---

# Advisory `allowed_to?` Never Consults the Catalog — Document the Asymmetry - Plan

## Goal Capsule

- **Objective:** document the one place the view and the gate can silently disagree — the advisory `allowed_to?` path resolves a decision by matching **grant rows for any string**, and never consults the permission catalog, while the Guard raises `ConfigurationError` for an uncataloged **gate** key. The consequence a reader must know: a typo'd or unrouted advisory key returns a **silent `false`** (indistinguishable from a real deny — a button hidden forever with no signal), and a **stale grant row** for a since-removed route makes the *same* key return a **silent `true`** (a control that renders but that no gate can enforce). Both are documented in the "Checking permissions" README section and at the `allowed_to?` point of use. **No engine behavior changes.**
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). The resolver decision order (SoD veto → full_access → org role → scoped role → deny), the **fail-closed** posture, one-org-role-per-subject, the resolver's **purity** (no writes, no per-decision state, ambient `CurrentAttributes` context), and the deliberate **route-derived catalog** are all **immutable**. This is a docs pass: it describes existing, correct, fail-closed behavior accurately; it does not alter a single decision path. The silent-`false` on a typo is *safe* (fail-closed) — it is a **diagnosability** gap, not a security hole.
- **Stop conditions:** stop and surface rather than guess if (a) closing the gap tempts a code change that makes the **resolver** (`lib/current_scope/resolver.rb#decide`) consult the catalog — that would couple the pure PDP to route-derived state and is out of scope here (it belongs to the enhancement sibling, see Cross-issue coupling); (b) any proposed fix would make the advisory path **raise** in a view/helper (a rendering-time raise is worse than a fail-closed `false` — Principle of Least Astonishment); or (c) writing the docs reveals the behavior differs from the issue's verified evidence (it does not — re-checked this session against `resolver.rb:33-47`, `guard.rb:41-46`, `role.rb:31-33`).

---

## Product Contract

> **Product Contract preservation:** documentation issue (`documentation` label), no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Finding filed and adversarially re-verified against gem source; see the issue body (`05_legacy_ui_overrides` scenario, both passing repro tests) and the evidence below.

### Summary

`Permissions#allowed_to?` → `CurrentScope.allowed?` → `Resolver#allow?` → `decide` resolves a permission purely by matching grant rows (`org_role.grants?`, `scoped_grant?`) against the resolved key string (`resolver.rb:33-47`). It never asks `CurrentScope.catalog.include?(key)`. The Guard's `current_scope_check!` **does** — it raises `ConfigurationError` before it ever calls `decide` when the gated key is uncataloged (`guard.rb:41-46`). That asymmetry produces two surprises on the advisory path, both absent from the docs where a reader would look:

1. **Typo / unrouted key → silent `false`.** `allowed_to?("reprots#show")` or `allowed_to?(:approve, report)` deriving `reports#approve` (a top-level `reports#approve` that has **no route**) returns `false` with no signal — byte-for-byte identical to a legitimate deny. The button is hidden forever and nothing tells the developer why.
2. **Stale grant row → silent `true`.** Insert a `RolePermission`/`ScopedRoleAssignment` row for a key whose route was later removed (via console/seeds/raw SQL), and `allowed_to?` returns `true` for a permission **no gate can enforce** and the role grid can no longer display — a phantom control.

Both are **fail-closed and internally consistent** — case 1 denies, case 2 permits only a view affordance that leads to a 403 or a dead route. The gap is diagnosability, not safety. This plan documents the asymmetry in the "Checking permissions" README section (grouped with the existing "Residual foot-gun" derivation-drift callout, since both are "advisory can disagree with the gate" hazards) and adds a one-line caveat to the `allowed_to?` method doc-comment at the point of use.

### Problem Frame

The gem's central promise, stated at the top of the README and enforced by routing every decision through one resolver, is that **the view and the gate agree** — a rendered control implies a permitted action. This is the *one* place a silent typo breaks that promise with no error anywhere in the system. The Guard is loud by design about uncataloged keys (it raises and tells you exactly how to fix it); the advisory path is silent by construction. A developer who typos an advisory key, or who leaves a stale grant row behind after deleting a controller, hits a debugging wall: the symptom (a button that's always hidden, or one that renders but hits a dead route or a `ConfigurationError`) gives no hint that the *key itself* is the problem. The supported write path already protects against half of case 2 — `Role#permission_keys=` filters uncataloged keys on save (`role.rb:31-33`), so the role grid can't create a stale grant — which means the phantom-`true` only arises from raw inserts or from a key that *was* cataloged when granted and whose route later disappeared. That nuance is exactly what the docs must capture so a reader knows where the phantom comes from and where it can't.

### Requirements

- **R1.** The "Checking permissions" README section states plainly that `allowed_to?` **never consults the permission catalog**: it answers "does the subject hold a grant for this exact key?", so any key with no matching grant returns `false` — whether the key is real-but-ungranted, typo'd, or unrouted, all indistinguishable.
- **R2.** The docs name the **typo → silent `false`** case explicitly: a misspelled or unrouted advisory key is indistinguishable from a genuine deny, and unlike the Guard (which raises `ConfigurationError` for an uncataloged **gate** key), the advisory path gives **no signal**.
- **R3.** The docs name the **stale grant row → silent `true`** case: a grant row for a since-removed route makes `allowed_to?` return `true` for a permission no gate enforces and the grid can't show — and state its only origins (raw `RolePermission`/`ScopedRoleAssignment` inserts via console/seeds, or a route removed after the grant was made), noting the role grid write path (`permission_keys=`) already filters uncataloged keys so it can't produce one.
- **R4.** The docs frame this honestly as **fail-closed** (case 1 denies; case 2 only exposes a view affordance that leads to a dead route (404) or a `ConfigurationError` — never a silent unauthorized allow) — a **diagnosability** gap, not a bypass — so a reader doesn't mistake it for a security hole.
- **R5.** The `allowed_to?` method doc-comment in `lib/current_scope/permissions.rb` carries a one-line caveat at the point of use, cross-linking the README section, so the asymmetry is visible where a developer reads what `allowed_to?` does.
- **R6.** Zero engine behavior change: no decision path, no fail-closed posture, no resolver purity, and no catalog derivation is altered by this plan.

---

## Key Technical Decisions

- **KTD-1 — Docs-only; zero behavior change (matches the repo's established docs-plan pattern, cf. `docs/plans/2026-07-15-011-docs-sod-gaps-plan.md`).** The behavior is correct and fail-closed. The honest fix is to *describe* the asymmetry, not to "fix" it by making the advisory path raise or by making the resolver catalog-aware. The route-derived catalog and the pure grant-row match are load-bearing design choices; changing either is an enhancement that belongs to a sibling issue (see Cross-issue coupling), not a docs pass.
- **KTD-2 — Any future code fix must NOT go in the resolver, and must NOT raise on the advisory path.** Two hard constraints for the deferred enhancement, recorded here so the docs don't imply otherwise: (a) `decide` is the shared, pure PDP used by *both* the Guard and advisory `allowed_to?`; adding a `catalog.include?` check there would couple the pure decision function to route-derived state and risk changing fail-closed behavior — the correct seam is the Guard-adjacent layer (`CurrentScope.allowed?` or a dev/test nudge mirroring `Guard#nudge_on_nil_sod_record`, which deliberately lives *outside* the resolver). (b) A view helper must never raise on an uncataloged key — a rendering-time `ConfigurationError` is a worse failure than a fail-closed `false` (Principle of Least Astonishment). The Guard raises because a mis-gated controller is a config error the developer must fix; a view button is not. This is why the enhancement is a *dev/test warning*, not symmetry with the Guard's raise.
- **KTD-3 — Extend the README, do not add a new guide file.** The gem keeps its whole narrative in `README.md` (`docs/` holds plans/roadmap/research/audit, no `docs/guides/` tree). The new callout sits directly after the existing "Residual foot-gun — namespaced/custom-named controllers" blockquote (`README.md`'s "Residual foot-gun — namespaced/custom-named controllers" note): both are cases where advisory derivation/matching disagrees with the authoritative gate, so grouping them is the correct information architecture — a reader debugging a "button shows but 403s / button never shows" symptom finds both foot-guns in one place.
- **KTD-4 — Anchor the phantom-`true` claim on the verified `permission_keys=` filter.** The docs must not over-state the stale-`true` risk: the supported UI write path (`role.rb:31-33`) already drops uncataloged keys, so the only ways to get a phantom grant are raw inserts or a route removed after granting. Stating this precisely (a) is accurate and (b) reassures a reader that normal role-grid usage can't create the phantom — the failure mode is narrow and self-inflicted.

---

## Implementation Units

### U1. README — "Checking permissions": advisory never consults the catalog

- **Goal:** make the advisory-vs-gate catalog asymmetry impossible to miss, in the section where a developer reads how `allowed_to?` resolves keys, covering both the silent-`false` (typo/unrouted) and silent-`true` (stale grant) directions and framing them as fail-closed diagnosability, not a bypass.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** none.
- **Files:** `README.md` (the "Checking permissions — anywhere" section, adding a callout directly after the existing "Residual foot-gun — namespaced/custom-named controllers" blockquote at ~154-163).
- **Approach:** add a **"Second foot-gun — `allowed_to?` never consults the catalog"** blockquote in the same style as the existing derivation-drift callout. State directly: `allowed_to?` asks only "does the subject hold a grant for this exact key?" — it never checks whether the key is in the permission catalog. So (1) a **typo'd or unrouted key returns `false` with no signal**, indistinguishable from a real deny — contrast the Guard, which *raises* `ConfigurationError` for an uncataloged gate key (`guard.rb:41-46`); and (2) a **stale grant row** (a `RolePermission`/`ScopedRoleAssignment` inserted by console/seeds for a key whose route was later removed) makes `allowed_to?` return `true` for a permission no gate enforces and the grid can't display. Note the role grid write path (`permission_keys=`) already filters uncataloged keys, so **normal UI usage can't create the phantom** — only raw inserts or a route removed after granting can (R3/KTD-4). Close by framing it honestly (R4): both are **fail-closed** — case 1 denies; case 2 only shows a view affordance that leads to a dead route (404) or a `ConfigurationError`, never a silent unauthorized allow — so this is a **debugging wall, not a bypass**; if a button is always hidden (silent `false`), or renders but hits a dead route / config error (silent `true`), suspect the *key* (typo, or route removed out from under a grant), and reach for the explicit full key to rule out derivation drift. Keep it directional and short (~8-12 lines), matching the surrounding voice.
- **Patterns to follow:** the existing "Residual foot-gun" blockquote (`README.md`'s "Residual foot-gun — namespaced/custom-named controllers" note) — same blockquote/bold-lead structure, same "Guard stays authoritative → this is a display bug, not a bypass" framing already used there; the honest plain-language tone of the "Denial behavior" and break-glass sections.
- **Test scenarios:** Test expectation: none — documentation only. The behavior it describes is already pinned by the two passing repro tests named in the issue evidence (`refute_includes 'approve-visible-from-reports'` for silent-`false`; `assert_includes` after a raw `RolePermission` insert for silent-`true`) in the `current_scope_test_scenarios` `05_legacy_ui_overrides` app; no new engine assertion is added.
- **Verification:** the rendered README "Checking permissions" section states, adjacent to the derivation-drift foot-gun, that (a) `allowed_to?` never consults the catalog, (b) a typo/unrouted key is a silent `false` with no signal (contrasted with the Guard's raise), (c) a stale grant row is a silent `true` and where it can/can't originate, and (d) both are fail-closed, a diagnosability gap not a bypass. A developer hitting an always-hidden button (silent `false`), or a button that renders but hits a dead route / config error (silent `true`), can now find, in that section, why the key itself may be the cause.

### U2. permissions.rb — `allowed_to?` doc-comment caveat at the point of use

- **Goal:** put a one-line pointer to the asymmetry at the exact place a developer reads what `allowed_to?` does, so the caveat travels with the API rather than living only in the README.
- **Requirements:** R5, R6.
- **Dependencies:** U1 (so the comment can point at the README callout U1 adds).
- **Files:** `lib/current_scope/permissions.rb` (the module/`allowed_to?` doc-comment block, ~lines 1-13).
- **Approach:** append one sentence to the existing doc-comment: `allowed_to?` returns `false` for **any** key the subject doesn't hold a grant for — including a **typo'd or uncataloged** key, which is indistinguishable from a real deny; unlike the Guard (which *raises* for an uncataloged gate key), the advisory path gives no signal and never consults the catalog (see README "Checking permissions"). Comment only — no code change (R6).
- **Patterns to follow:** the existing multi-line doc-comment style already on `Permissions` and on the accessors in `configuration.rb`; the point-of-use doc-comment pattern used by `docs/plans/2026-07-15-011-docs-sod-gaps-plan.md` U3 (a one-sentence caveat at the seam where the reader acts). Keep it terse, matching the house voice.
- **Test scenarios:** Test expectation: none — comment-only change with no runtime surface.
- **Verification:** the `allowed_to?` doc-comment mentions that uncataloged/typo'd keys resolve to a silent `false` and points at the README; `bin/rubocop` clean (comment-only, no offenses); no behavior change (the engine suite is untouched and green).

---

## Scope Boundaries

**In scope:** a README callout in the "Checking permissions" section documenting the advisory catalog-non-consultation asymmetry (both directions), and a one-sentence `allowed_to?` doc-comment caveat. Documentation of **existing, correct, fail-closed** behavior only.

**Explicit non-goals (preserve deliberate design):**
- Making the **resolver** (`decide`) consult the catalog — it is the shared pure PDP for both the Guard and advisory; catalog-awareness there couples it to route-derived state and risks fail-closed behavior (KTD-2). Not this issue.
- Making the advisory path **raise** on an uncataloged key — a rendering-time raise is worse than a fail-closed `false` (KTD-2, Principle of Least Astonishment). Not this issue.
- Adding a `config.warn_on_uncataloged_advisory_key` dev/test warning flag (the enhancement floated in the issue's "How", mirroring `warn_on_nil_sod_record`) — a real, additive, default-off code change, but its own issue (see Cross-issue coupling), not part of a `documentation`-labeled pass. This plan describes current behavior; the enhancement changes it.
- Any auto-reconciliation of stale grant rows against the catalog (a data-migration/cleanup concern). Not this issue.
- Any new `docs/guides/` file — the README is the gem's single narrative home (KTD-3).

**Deferred to follow-up work:**
- The dev/test warning for uncataloged advisory keys — see Cross-issue coupling (#45).
- A stale-grant-row detector / catalog reconciliation report (boot-time or CI advisory listing grant rows whose key left the catalog) — natural report-only-mode territory; see Cross-issue coupling (#46, #37).

---

## Open Questions

- **Does the enhancement (#45) belong folded into this plan?** Assumed **no** — the issue carries the `documentation` label and the repo's precedent (`2026-07-15-011-docs-sod-gaps-plan.md`) keeps behavior changes out of docs passes and defers them to siblings. If the maintainer would rather land the dev/test warning here, add a third unit adding `config.warn_on_uncataloged_advisory_key` (default `false`, dev/test only, emitted from the `CurrentScope.allowed?` seam — **never** the resolver, **never** a raise — mirroring `Guard#nudge_on_nil_sod_record`), and update the README callout to point at it. Flagged, not decided here.
- **Callout placement — one grouped foot-gun block or two?** Assumed a **separate adjacent blockquote** right after the derivation-drift one, since the two hazards have different causes (key *shape* mismatch vs. key *existence*) even though both are "advisory disagrees with the gate." Adjust to a single merged "Foot-guns" block if the maintainer prefers fewer callouts.

---

## Cross-issue coupling

- **Enhancement sibling #45 (dev/test warning for uncataloged advisory keys).** This docs plan describes the current silent behavior; #45 would *change* it by adding an opt-in, default-off `warn_on_uncataloged_advisory_key` that logs (never raises) when `allowed_to?` resolves a key absent from the catalog — the diagnosability fix that the silent-`false` case cries out for. They compose cleanly: land the docs now; if #45 ships, its plan owns updating U1's callout and U2's doc-comment to point at the new flag. The design constraints for #45 are already fixed in KTD-2 (Guard-adjacent seam, never the resolver, never a raise) — name that dependency in #45 so the implementation doesn't drift into the pure PDP.
- **Enhancement sibling #46 (stale-grant-row reconciliation / catalog authority for advisory).** The phantom-`true` case (U1's second direction) is what #46 would address — either a report that lists grant rows whose key has left the catalog, or making the advisory path treat an uncataloged key as ungranted regardless of a stale row. If #46 lands the latter, U1's "stale grant row → silent `true`" paragraph must be revised (the phantom would no longer occur). Compose by: document the current phantom now; #46 owns amending the paragraph if it changes the behavior.
- **Report-only / adoption-guide cluster (#37 report-only ↔ #26 adoption guide).** The stale-grant detector deferred above is natural report-only-mode territory (#37); the adoption guide (#26) is where new adopters should meet the "advisory never consults the catalog" caveat before they ship a typo'd `allowed_to?` or a raw seed grant — cross-link this README callout from #26 so it's encountered during onboarding, not during a 3am debugging session.
- **Denial-behavior docs (#24, `docs/plans/2026-07-15-006-docs-denial-behavior-plan.md`).** That plan documents *why a permitted-looking action denies*; this one documents *why a rendered-looking control was never permitted*. They are the two halves of "view/gate disagreement" — U1 should stay consistent with (and may cross-link) the denial-behavior section's framing that the Guard is authoritative and the view is advisory.
