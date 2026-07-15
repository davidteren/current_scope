---
title: Whole-Controller Wildcard Grants in the Model API (`controller#*`) - Plan
type: feat
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/42
---

# Whole-Controller Wildcard Grants in the Model API (`controller#*`) - Plan

## Goal Capsule

- **Objective:** give programmatic callers (seeds, bootstrap scripts, console, tests) a first-class "grant every action on this controller" token — `role.permission_keys = %w[reports#*]` — that expands against the live catalog at write time, so seeds stop enumerating 16 keys by hand and stop going stale when a controller gains an action. This is the model-API equivalent of the grid's per-row "enable all" checkbox, which today is JS-only sugar (`app/assets/javascripts/current_scope/application.js` row-master).
- **Authority hierarchy:** this plan → the settled v0.1 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). The engine invariants are **immutable** and this feature touches none of them: resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **purity** (no writes / no per-decision state), and ambient `CurrentAttributes` context. The whole point of choosing **expand-at-write** (KTD-1) is that nothing downstream of the `Role#permission_keys=` setter ever sees a wildcard — the resolver, the grid, `grants?`, `scope_for`, and the audit ledger all continue to operate on concrete `controller#action` keys exactly as today.
- **Backward compatibility:** purely **additive**. A `permission_keys=` assignment that contains no `#*` token is byte-for-byte unchanged. No config knob, no default flip, no migration. The route-derived catalog and its deliberate silent-drop-of-stale-keys behavior are preserved, not changed.
- **Stop conditions:** stop and surface rather than guess if (a) any design pressure would push wildcard expansion *past* the setter into resolve-time storage of a literal `#*` key (that would touch the resolver/grid/audit and break the "concrete keys only" invariant — see KTD-1), (b) a proposal would make a wildcard expand to something a matching enumeration would NOT grant (expansion must be exactly `catalog.grouped[controller]`), or (c) the change would alter what a wildcard-free assignment stores or drops.

---

## Product Contract

> **Product Contract preservation:** enhancement, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded in issue #42, whose finding is verified against source (`app/models/current_scope/role.rb:31-33`, `lib/current_scope/permission_grid.rb:65-73`, `app/controllers/current_scope/roles_controller.rb:130-131`).

### Summary

Teach `Role#permission_keys=` to recognize a `controller#*` wildcard token and expand it, at assignment time, into the concrete `controller#action` keys the catalog currently routes for that controller — then run the existing exact-catalog filter over the result. A wildcard for a controller that routes nothing expands to nothing and is dropped, consistent with the setter's existing silent handling of stale keys. Storage, audit, the grid, and the resolver are untouched: they still see only concrete keys. The engine ships the token plus a documented seeds recipe.

### Problem Frame

Seeds and bootstrap scripts are how real apps actually manage roles, and "grant everything on this controller" is the most common bulk intent. Today the only programmatic path is to enumerate every action:

```ruby
role.permission_keys = CurrentScope.catalog.grouped["reports"].map { |a| "reports##{a}" } # 16 keys
```

That enumeration is verbose and, worse, **goes stale**: add a `reports#export` action next quarter and every seed that "grants all of reports" silently omits it. The grid solves this in the UI — the row-master checkbox ticks every action of a controller — but that convenience lives only in JavaScript (`application.js`), so the console/seed/test caller gets no equivalent. And because `permission_keys=` filters against exact catalog keys (`role.rb:32`), a hopeful `permission_keys = %w[reports#*]` is silently dropped like any non-catalog key — the worst outcome: no error, no grant. Note the grid's *group* tokens (`controller:read`) already expand at write time via `PermissionGrid#expand`; this feature gives the programmatic API the same expand-at-write treatment for a whole-controller token.

### Requirements

- **R1.** A `controller#*` token in a `permission_keys=` assignment expands to exactly the set the catalog currently routes for that controller — `CurrentScope.catalog.grouped[controller]` mapped to `controller#action` keys. An assignment `%w[reports#*]` stores the same concrete rows as manually enumerating all of `reports`'s routed actions today.
- **R2.** Expansion is **additive and order-independent**: a wildcard composes with explicit keys and other wildcards in the same assignment (`%w[reports#* projects#approve]`), and duplicates produced by overlap (`%w[reports#* reports#approve]`) collapse via the existing `uniq`.
- **R3.** A `controller#*` for a controller the catalog routes nothing for (unknown, excluded, or un-routed) expands to zero keys and is dropped — no raise, no stored `#*` row — exactly matching the setter's existing silent-drop of stale/non-catalog keys (**fail-closed, no surprise**).
- **R4.** Namespaced controllers work: `admin/reports#*` expands against the `admin/reports` catalog bucket (controllers never contain `#`, so the wildcard boundary is the final `#`).
- **R5.** Nothing downstream of the setter observes a wildcard. Stored `role_permissions` rows, `permission_keys`, `grants?`, the `permission_keys_change` diff, the `role.created`/`role.updated` audit details, the grid, and the resolver all continue to see only concrete `controller#action` keys. (This is the invariant that keeps the change additive.)
- **R6.** A wildcard-free assignment is byte-for-byte unchanged — same keys stored, same stale keys dropped, same diff computed.

---

## Key Technical Decisions

- **KTD-1 — Expand-at-write, not match-at-resolve (the load-bearing fork).** The issue names both: (a) expand `controller#*` into concrete keys when it is assigned, storing the snapshot; or (b) store a literal `reports#*` row and expand it dynamically at every resolve. **Pick (a).** Match-at-resolve is a materially larger and riskier change — it would put a wildcard into `role_permissions`, forcing the resolver, `grants?`, `scope_for`, the grid's cell/checked logic, and the audit ledger to each learn to interpret `#*`, and it would touch the resolver's hot path. Expand-at-write confines the entire feature to one setter, keeps storage in its current concrete-key shape, and preserves every engine invariant untouched (R5). It also matches how the grid's *group* tokens already behave (`PermissionGrid#expand` — `permission_grid.rb:65-73` — expands then stores concrete keys). The only semantic cost is honestly stated below.
- **KTD-2 — Static snapshot semantics, documented.** Because we expand at write, a wildcard grant is a snapshot: adding a `reports#export` action later does NOT retroactively appear in a role saved earlier with `reports#*` — the role must be re-saved to pick it up. This is the same staleness the manual enumeration has today, so the feature is strictly better (shorter, and current at each save) without introducing a *new* dynamic-follow expectation. Match-at-resolve would follow new actions automatically, but that is a different and heavier product (a stored intent that silently widens a grant when routes change — arguably a surprise of its own). Documented in the README recipe so no one is astonished.
- **KTD-3 — The single seam is `Role#permission_keys=`, and it covers every caller.** Seeds, console, tests, AND any future controller/API post all route their permission writes through this one setter (the roles controller builds `permission_keys` then assigns via `update`). One guard here is the whole fix; there is no per-caller patch and no sibling path left broken. The grid's JS row-master is untouched — it ticks individual boxes client-side and still posts concrete keys, so it neither needs nor gains the token.
- **KTD-4 — Catalog owns the controller→keys expansion.** Add `PermissionCatalog#keys_for(controller)` returning the routed `controller#action` keys for one controller (or `[]`), rather than reaching into `catalog.grouped[...]` from the model. The catalog already owns key derivation and the `grouped`/`include?` surface; the setter should ask it, not re-derive the `"#{controller}##{action}"` join in a second place. Small, and it keeps the wildcard's notion of "everything on this controller" identical to what the grid renders.
- **KTD-5 — No global `*` / `*#*` token.** Scope is whole-*controller* only, as the issue asks. "Grant literally everything" already has a first-class, safer home: `full_access` on the role. A cross-controller wildcard would duplicate that with none of its explicit intent, so it is a deliberate non-goal (see Scope Boundaries), not an oversight.

---

## Implementation Units

### U1. `PermissionCatalog#keys_for(controller)` — routed keys for one controller

- **Goal:** expose the concrete `controller#action` key set for a single controller, as the one place that knows how to enumerate "everything on this controller."
- **Requirements:** R1, R3, R4.
- **Dependencies:** none.
- **Files:** `lib/current_scope/permission_catalog.rb`, `test/permission_catalog_test.rb`.
- **Approach:** add a public method that reads the already-computed `grouped` map and maps one bucket back to full keys:

  ```ruby
  # directional
  def keys_for(controller)
    (grouped[controller] || []).map { |action| "#{controller}##{action}" }
  end
  ```

  Returns `[]` for an unknown/excluded/un-routed controller (fail-closed, R3). Namespaced controllers fall out for free because `grouped` already keys on the full `controller#action`-derived controller string (R4).
- **Patterns to follow:** the existing `grouped`/`include?` accessors in `permission_catalog.rb`; the `"#{controller}##{action}"` join already used in `PermissionGrid#cell`/`#expand`.
- **Test scenarios:**
  - Known controller with several routed actions → returns exactly `["reports#approve", "reports#create", ...]` equal to enumerating `grouped["reports"]` (input `"reports"` → expected the full routed set).
  - Namespaced controller (`"admin/reports"`) → returns the `admin/reports#*` action keys (input `"admin/reports"` → expected namespaced keys).
  - Unknown controller (`"nope"`) → `[]`.
  - Excluded controller (matches `excluded_controllers`, e.g. `"current_scope/roles"`) → `[]` (it isn't in the catalog, so it isn't in `grouped`).
- **Verification:** catalog test green; `keys_for` output is identical to the manual `grouped[c].map { ... }` enumeration for a routed controller and `[]` otherwise; RuboCop clean.

### U2. `Role#permission_keys=` — expand `controller#*` before the catalog filter

- **Goal:** recognize the `controller#*` token and replace it with `keys_for(controller)` *before* the existing exact-catalog filter runs, so expanded concrete keys survive the filter and wildcards for empty controllers drop.
- **Requirements:** R1, R2, R3, R4, R5, R6.
- **Dependencies:** U1.
- **Files:** `app/models/current_scope/role.rb`, `test/models/role_test.rb`.
- **Approach:** change the setter (`role.rb:31-33`) to flat-map each incoming token through a wildcard expander, then keep the existing `uniq` + `include?` filter untouched:

  ```ruby
  # directional
  def permission_keys=(keys)
    expanded = Array(keys).flat_map { |k| expand_wildcard(k) }
    @pending_permission_keys = expanded.uniq.select { |k| CurrentScope.catalog.include?(k) }
  end

  def expand_wildcard(key)
    str = key.to_s
    return str unless str.end_with?("#*")

    CurrentScope.catalog.keys_for(str.chomp("#*")) # [] for unknown → dropped
  end
  ```

  Boundary is the trailing `#*` (a controller never contains `#`, so `chomp("#*")` yields the exact controller string, incl. namespaced — R4). Expanded keys are already concrete catalog keys, so the unchanged `include?` filter passes them (R1) and a no-route wildcard yields `[]` → nothing added (R3). Non-wildcard tokens pass through the flat_map as a single element, so `uniq`/`include?` behave exactly as before (R6). Storage, diff, and audit stay concrete because expansion happens before anything is staged (R5).
- **Execution note:** this is a grant-widening path — write the failing tests first (assert the *stored* rows, not just the setter return) and watch the "wildcard currently silently dropped" case go from red to green, so the fix is proven at the persistence boundary, not just in memory.
- **Patterns to follow:** the setter's existing `Array(keys).uniq.select { include? }` shape (extend, don't rewrite); `PermissionGrid#expand`'s expand-then-store precedent for group tokens.
- **Test scenarios:**
  - **Happy path (was silently dropped):** `role.permission_keys = %w[reports#*]; role.save!` → `role.reload.permission_keys` equals the full routed set for `reports` (input `%w[reports#*]` → expected all `reports#action` rows persisted).
  - **Equivalence:** a wildcard assignment and a manual full enumeration of the same controller persist an identical row set.
  - **Compose with explicit keys:** `%w[reports#* projects#approve]` → all of reports plus `projects#approve`.
  - **Multiple wildcards:** `%w[reports#* projects#*]` → union of both controllers' routed keys.
  - **Overlap dedup:** `%w[reports#* reports#approve]` → each concrete key once (no duplicate rows).
  - **Unknown controller wildcard:** `%w[nope#*]` → drops to zero, no stored `#*` row, no raise (R3).
  - **Namespaced:** `%w[admin/reports#*]` → expands against `admin/reports` (R4).
  - **Regression (no wildcard):** `%w[reports#approve bogus#missing]` → stores `reports#approve`, drops the stale key — identical to pre-change behavior (R6).
  - **Downstream stays concrete:** after a wildcard save, `role.grants?("reports#approve")` is true, `permission_keys_change[:added]` lists concrete keys (no `#*`), and no persisted row equals `"reports#*"` (R5).
- **Verification:** role model test green; existing `test/models/role_test.rb` and the grid/controller tests unchanged and passing; a persisted role never contains a `#*` row; RuboCop clean.

### U3. Documentation — seeds recipe and snapshot semantics

- **Goal:** document the token where seed authors look, and state the snapshot (expand-at-write) semantics plainly so no one expects new actions to appear in an already-saved wildcard grant.
- **Requirements:** R1, R2, and the KTD-2 honesty mandate.
- **Dependencies:** U1, U2.
- **Files:** `README.md` (the programmatic-grant / seeds area near the `CurrentScope.grant!` bootstrap block and the "Testing your app" `grant_role!` recipe), `docs/ROADMAP.md` / `STATUS.md` (mark the enhancement landed).
- **Approach:** add a short subsection showing `role.permission_keys = %w[reports#*]` as the seed-friendly way to grant a whole controller, contrasted with the verbose enumeration it replaces. State three things explicitly: (a) it expands against the **current** routes at save time — a **snapshot**, not a live-follow, so re-save to pick up newly added actions (KTD-2); (b) a wildcard for a controller that routes nothing is dropped silently, same as any stale key (R3); (c) for "grant literally everything," use `full_access`, not a wildcard (KTD-5). Note that the grid's row-master checkbox is the UI equivalent, so console/seed and UI now have parity.
- **Test expectation:** none — documentation only.
- **Verification:** README renders; the seeds snippet is copy-runnable; the snapshot caveat is stated; `STATUS.md`/roadmap item moved to done.

---

## Scope Boundaries

**In scope:** the `PermissionCatalog#keys_for` helper, the `controller#*` expansion in `Role#permission_keys=`, tests at the catalog and persisted-role boundaries, and the seeds/docs recipe — engine only, additive, no config.

**Out of scope / preserved design choices:**
- **The route-derived catalog** stays the source of truth; this feature reads it, never adds a stored wildcard row or a wildcard-aware storage format.
- **The grid JS row-master** (`application.js`) is untouched — it already posts concrete keys client-side and needs nothing.
- **Match-at-resolve / dynamic-follow wildcards** — explicitly rejected (KTD-1/KTD-2). Would require touching the resolver, grid, and audit and would change grant semantics.

**Deferred to Follow-Up Work (tangential):**
- A convenience `role.grant_controller!("reports")` mutator. The `permission_keys = existing + %w[reports#*]` token already expresses this; a dedicated method is redundant sugar unless usage shows the additive form is awkward (e.g. wanting to add without re-reading the current set).
- Surfacing `#*` as an accepted token in the *management UI* (a per-row "grant all" that posts a wildcard instead of relying on JS). The JS path already works; only add if progressive-enhancement-off parity is later wanted.

**Explicit non-goals:** a global `*` / `*#*` "everything everywhere" token (use `full_access`); any change to how wildcard-free assignments store or drop keys; any resolver, `scope_for`, or audit change.

---

## Open Questions

- **Silent drop vs. warn on an empty wildcard.** R3 keeps `nope#*` (and `reports#*` when reports routes nothing) silent, matching the setter's existing stale-key behavior — consistent, but a typo'd controller in a seed grants nothing with no signal. Is a dev/test-only warning (mirroring `warn_on_nil_sod_record`'s opt-in style) wanted for an all-empty expansion, or is consistency with today's silent drop preferred? Assumed: silent, for consistency and zero config.
- **Snapshot vs. dynamic is settled here (KTD-2) but is a genuine product fork.** If a maintainer wants wildcard grants to *follow* new actions automatically, that is the match-at-resolve design this plan deliberately rejected — reopen as a separate, larger issue rather than bending this one.

---

## Cross-issue coupling

- **Companion to the #20↔#21 "grant intent gets silently dropped" cluster.** #20 (permission_keys drop) and #21 (`bypass_sod` ungrantable) share this issue's root shape: `Role#permission_keys=`'s exact-catalog filter silently discards tokens it doesn't recognize. This plan makes that same setter *recognize* one new class of token (`controller#*`) instead of dropping it. If #20/#21 are being addressed around a "surface dropped keys" change to the setter, coordinate: the wildcard expander added here (U2) must run **before** any such drop-detection, so an expanded wildcard is never reported as a dropped key, and an empty-expansion wildcard is reported (if at all) as one deliberate no-op rather than N missing keys. One shared setter, one place to reconcile both behaviors.
