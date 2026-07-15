---
title: Permission Grid at Scale — Fold One-Off Columns, Tooltips, Namespace Grouping, Descriptions - Plan
type: feat
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/38
---

# Permission Grid at Scale — Fold One-Off Columns, Tooltips, Namespace Grouping, Descriptions

## Goal Capsule

- **Objective:** make the role-editor permission grid scale to real-world, custom-action-heavy apps. Four presentation fixes, in value order: (1) fold *single-controller* one-off actions out of the global column axis into a per-row disclosure so the grid stops widening O(distinct action names); (2) reveal each group column's member actions via a `title` tooltip; (3) group/order namespaced controllers so `admin/reports` and `reports` sit together; (4) allow optional host-supplied human descriptions per permission, surfaced as tooltips.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). **This is a presentation-layer change only.** The resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, **resolver purity** (no writes, no per-decision state, ambient `CurrentAttributes` context), and the route-derived catalog are all **immutable and untouched**. No file under `lib/current_scope/resolver.rb`, `guard.rb`, `mutation_guard.rb`, `context.rb`, or `permission_catalog.rb`'s derivation logic changes behavior.
- **Grid-local invariants that MUST be preserved (this plan's blast radius):**
  - **Escalation guard.** A partial group cell renders unchecked+indeterminate and round-trips its exact granted subset via hidden inputs (`permission_grid.rb:45-61`, `edit.html.erb:73-75`). A checked group token expands to the whole group on save, so "some granted" must never render as checked. Folding must not touch group-cell semantics.
  - **Round-trip fidelity.** Submitted `role[permission_keys][]` (raw keys) and `role[permission_groups][]` (`controller:group` tokens) expand deterministically in `PermissionGrid#expand` / `RolesController#role_params`. Folded one-off cells emit the **identical** `role[permission_keys][]` checkbox they emit today as a column — same `name`, same `value` — just relocated in the DOM. No controller/param change.
  - **Aligned matrix.** The remaining fixed columns stay aligned: a controller that doesn't route a column's actions shows a blank cell, never a shifted one.
- **Stop conditions — surface, don't guess, if:** (a) any change would alter a submitted checkbox's `name`/`value` (round-trip risk); (b) folding would let a partial group render as checked (escalation risk); (c) the namespace ordering would drop or duplicate a controller row; (d) delivering descriptions would require the engine to *store* metadata rather than read host-supplied i18n (that is a catalog/data-model change and out of scope — see KTD-4).

---

## Product Contract

> **Product Contract preservation:** enhancement cluster from issue #38, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded in the verified findings in the issue body (six local scenario apps, adversarially re-checked against gem source).

### Summary

At god-controller / custom-action scale the editable grid degrades: `PermissionGrid#leftover_actions` (`permission_grid.rb:85-88`) builds a **global union** of every ungrouped action name, and each becomes a grid-wide column (`columns`, line 31). A legacy controller with 27 non-CRUD actions therefore adds ~28 columns that are blank for every *other* row — measured 65–70% blank cells and a table ~2.3 viewports wide. This plan folds actions that are routed by **exactly one controller** out of the column axis and into that controller's own inline disclosure ("+9 custom actions…"), keeping the aligned matrix for CRUD groups and genuinely shared custom actions (e.g. `approve` on many controllers). It also adds group-header tooltips, namespace-aware row grouping, and optional per-permission descriptions. All four are presentation-only and preserve the escalation guard and the submitted-params contract byte-for-byte.

### Problem Frame

The editable grid is the product's flagship surface, and its target audience — god controllers and custom-action-heavy legacy apps — is exactly where it looks worst. Today an admin editing a role scrolls a 2894px-wide matrix (nowrap uppercase mono headers) hunting the single non-blank cell in each sparse column; group headers ("read", "workflow") don't say what they grant; namespaced siblings scatter alphabetically; and every label is a bare route-derived string with no human meaning. None of this affects *enforcement* (independence and alignment are correct and verified) — it is purely that the grid does not scale as a UI. That is worth fixing precisely because the grid is where adoption happens.

### Requirements

- **R1.** An action routed by **exactly one** controller and not covered by any group ("one-off") is removed from the global column axis and rendered inside that controller's row as an inline disclosure listing its own one-off actions as checkboxes. Grid width becomes O(groups + *shared* custom actions), independent of the count of one-off actions.
- **R2.** A folded one-off checkbox submits the **identical** `role[permission_keys][]` name and `controller#action` value it submits as a column today; grant/save/round-trip is unchanged. A role's existing keys are reflected as checked in the disclosure.
- **R3.** A custom action routed by **two or more** controllers stays an aligned column (it is not sparse); the fold applies only to true singletons.
- **R4.** Folding is controlled by `config.permission_grid_fold_custom_actions` (default **true**). Set false to restore the pre-#38 flat matrix exactly (escape hatch for hosts asserting exact column counts). Group columns and shared-leftover columns are unaffected by the flag.
- **R5.** Each **group** column header carries a `title` tooltip enumerating its member actions (e.g. `read = index, show`). Data comes from the existing `Column#actions`; non-group (single-action) columns need no tooltip.
- **R6.** Controllers are ordered so namespaced siblings of the same base resource are adjacent (`admin/reports` next to `reports`), and namespaced rows carry a visible namespace hint. Row set is otherwise unchanged — no controller dropped, added, or duplicated; enforcement independence is untouched.
- **R7.** An optional host-supplied description per permission (via i18n) surfaces as a tooltip on the relevant cell/disclosure item. Absent a translation, the grid renders exactly as without the feature (no placeholder, no error). The engine stores no new metadata.
- **R8.** With `config.permission_grid_fold_custom_actions = false` and no i18n descriptions defined, the grid is byte-for-byte the pre-#38 grid except for the additive group-header `title` attribute (R5) and namespace ordering (R6), both of which are non-breaking presentation.

---

## Key Technical Decisions

- **KTD-1 — Fold only *single-controller* one-off actions; keep shared custom actions as columns.** The sparseness is caused specifically by columns that exactly one row uses (1 non-blank cell + N−1 blanks). An `approve` action shared by five controllers reads fine as an aligned column and *should* stay one — folding it would scatter a coherent concept into five disclosures. So the split is: `leftover action routed by ≥2 controllers → column; routed by exactly 1 → fold into that controller's disclosure`. This is the sharpest cut that kills the width blow-up while preserving the aligned-matrix value the grid was designed around (`permission_grid.rb:2-11`). Directional predicate: partition `leftover_actions` by `@grouped.values.count { |acts| acts.include?(action) }`.
- **KTD-2 — Folding is presentation-only; the submitted checkbox is unchanged.** A one-off leftover cell today emits `name: "role[permission_keys][]", value: "controller#action"` (`permission_grid.rb:55-56`, `value: keys.first` for a single-action column). The disclosure emits the *same* checkbox, only relocated in the DOM. `PermissionGrid#expand`, `RolesController#role_params`, and the model's `permission_keys=` are **not touched** — this is why folding cannot regress the round-trip (R2) and needs no controller change. Singletons have no partial-group concern, so the escalation guard is untouched.
- **KTD-3 — Default-on with an opt-out flag, not a silent default change.** Changing a flagship surface's default layout is a real behavior change: the scenario/host tests assert exact header counts (issue evidence: "18/21 header counts"), so a silent flip would break them and surprise upgraders. Least-astonishment says ship the better default (`fold_custom_actions = true`) but give a one-line escape hatch (`= false` restores the old matrix) and document the change in the upgrade notes. This mirrors how `permission_grid_groups` already exposes the grouping policy as config rather than hardcoding it (`configuration.rb:120-130`).
- **KTD-4 — Descriptions are host-supplied i18n, not engine-stored metadata.** The catalog is deliberately route-derived and table-free (`permission_catalog.rb:22-31`); giving permissions descriptions must not add a metadata store or a migration. Lookup `I18n.t("current_scope.permissions.<controller>.<action>", default: nil)` at render time — a host that wants descriptions adds a locale file, everyone else sees today's grid. Zero engine data-model change, graceful when absent (R7). **If a future requirement needs descriptions the engine owns, that is a separate catalog change and explicitly out of scope here.**
- **KTD-5 — Namespace grouping is a sort + a visual hint, not collapsible sections (yet).** The finding is a papercut: related rows should be adjacent with a hint they CRUD the same model. The smallest correct fix is a comparator that orders by `[base_resource, full_path]` (last path segment, then full path) so `admin/reports` and `reports` become adjacent, plus a subtle namespace badge/indent on namespaced rows. Full collapsible `admin/*` section headers with rowspans are deferred — they touch row rendering far more and the papercut doesn't warrant it. Trade-off named in Open Questions: this reorders the whole row list (documented, non-breaking).

---

## High-Level Technical Design

The grid gains a second render region per row (the custom-actions disclosure) alongside the existing fixed-column cells. The column axis shrinks to groups + shared-leftover columns; singletons move into rows. Nothing below the presentation layer moves.

```mermaid
flowchart TD
    A[catalog.grouped: controller -> actions] --> B[PermissionGrid]
    B --> C{leftover action\nrouted by how many\ncontrollers?}
    C -- ">= 2 (shared)" --> D[aligned COLUMN\n(unchanged)]
    C -- "exactly 1 (singleton)\nAND fold flag on" --> E[custom_actions_for controller\n-> per-row disclosure]
    B --> F[group columns\n(unchanged) + title tooltip]
    B --> G[controllers ordered by\n base_resource, full_path\n+ namespace hint]
    D --> H[edit.html.erb: thead + matrix cells]
    F --> H
    E --> I[edit.html.erb: <details> disclosure in row]
    G --> H
    H --> J[submitted role[permission_keys][] / role[permission_groups][]\nIDENTICAL to today]
    I --> J
```

*Directional — prose and requirements are authoritative.* The single seam that carries the security-relevant guarantee is J: every checkbox a folded action emits is the same one the flat matrix emits, so the round-trip and escalation guard are unaffected.

---

## Implementation Units

### U1. Grid model: partition leftover actions into shared columns vs folded singletons

- **Goal:** teach `PermissionGrid` to keep shared custom actions as columns and expose each controller's single-controller one-off actions for a per-row disclosure, behind the fold flag.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** U0 (config knob — see U5 note; keep it a tiny standalone edit or land it here).
- **Files:** `lib/current_scope/permission_grid.rb`, `test/permission_grid_test.rb`.
- **Approach:** split `leftover_actions` (line 85) into `shared_leftover_actions` (action name whose routing-controller count ≥ 2) and per-controller singletons. `columns` (line 27-32) appends only `shared_leftover_actions` as `Column(group: false)` when folding is on (unchanged set when the flag is off). Add `custom_actions_for(controller)` returning that controller's singleton actions as `Cell`s built through the **existing** `cell`/singleton path (so `name`/`value` are identical to a one-off column cell today — KTD-2). Directional: `routing_count = ->(action) { @grouped.values.count { |acts| acts.include?(action) } }`; `singleton?(action) = routing_count.call(action) == 1`. When `fold_custom_actions` is false, `custom_actions_for` returns `[]` and `columns` behaves exactly as today.
- **Patterns to follow:** the existing `Struct` cells, the `any_controller_has?`/`actions_for` helpers, and the `columns` filter_map shape already in the file.
- **Test scenarios:**
  - Two controllers each with a unique custom action + one shared custom action → shared action is a column; each unique action is absent from `columns` and present in its own `custom_actions_for` (input: grouped `{a: [x, appr], b: [y, appr]}`, groups CRUD → columns include `approve`, exclude `x`,`y`; `custom_actions_for("a") == [x]`).
  - Singleton cell's `name`/`value` equal the value the flat-matrix column cell produced for the same key (regression guard on R2).
  - `fold_custom_actions = false` → `columns` and blank-cell layout identical to pre-change (assert against the current 18/21-style counts).
  - A one-off action that is *also* a group member (e.g. `show`) is never folded (it's not leftover).
  - Controller with zero one-off actions → `custom_actions_for` returns `[]` (no empty disclosure).
- **Verification:** `test/permission_grid_test.rb` green including a flag-off parity case; RuboCop omakase clean.

### U2. Edit view + CSS: render the custom-actions disclosure and group-header tooltips

- **Goal:** render each row's folded singletons as an inline native disclosure, and add a `title` to group column headers listing member actions.
- **Requirements:** R1, R2, R5.
- **Dependencies:** U1.
- **Files:** `app/views/current_scope/roles/edit.html.erb`, `app/assets/stylesheets/current_scope/application.css`, `test/integration/role_grid_test.rb`.
- **Approach:** header (line 38-39): when `column.group`, add `title: column.actions.join(", ")` (or `"#{label} = #{actions.join(', ')}"`); leave single-action columns untitled (R5). In each row (after the fixed cells, line 78), when `grid.custom_actions_for(controller).any?`, render a native `<details>`/`<summary>` ("+N custom actions…") containing one `<label><%= check_box_tag cell.name, cell.value, cell.checked … %></label>` per folded cell — reusing the exact cell markup from lines 63-69. No JS dependency for correctness (native disclosure; progressive-enhancement consistent with the `data-cs-row-all` note at line 47). CSS: a compact disclosure block styled to sit under the row; keep CSP-safe, no web fonts (matches `application.css` house style). Ponytail: reuse `<details>`, no custom toggle JS.
- **Patterns to follow:** the existing cell `<label>`/`check_box_tag` block (lines 63-69), the `cs-hint`/`cs-grid` class conventions, and the "kept in the a11y tree" alignment comments.
- **Test scenarios:**
  - Grid HTML for a group column contains `title="index, show"` (or chosen format) on the `<th>` (R5).
  - A controller with a one-off action renders a `<details>` whose summary counts the folded actions and whose checkbox has `name="role[permission_keys][]"` and `value="controller#action"` (R1/R2).
  - Checking a folded box and saving grants exactly that key (integration POST through `test/dummy`), and an already-granted one-off renders checked.
  - `fold_custom_actions = false` → no `<details>`, one-off actions reappear as columns (parity).
  - Blank/aligned cells for the fixed columns are unchanged (no shifted cell).
- **Verification:** `test/integration/role_grid_test.rb` green; a folded grant round-trips through create/update; visual check that the god-controller grid no longer widens with one-off actions.

### U3. Namespace-aware row ordering + namespace hint

- **Goal:** order controllers so same-resource namespaced siblings are adjacent, and mark namespaced rows.
- **Requirements:** R6.
- **Dependencies:** none (independent of U1/U2; composes in the same view).
- **Files:** `lib/current_scope/permission_grid.rb` (`controllers`, line 21-23), `app/views/current_scope/roles/edit.html.erb` (row header, line 46-54), `test/permission_grid_test.rb`, `test/integration/role_grid_test.rb`.
- **Approach:** replace `@grouped.keys.sort` with a comparator sorting by `[base_resource, full_path]` where `base_resource = path.split("/").last` — so `reports` and `admin/reports` become adjacent (KTD-5). In the row `<th scope="row">`, when the controller path contains `/`, render the namespace segment(s) as a subtle badge/prefix (e.g. muted `admin/` before `reports`) so the admin sees the surface is distinct. Directional: `controllers.sort_by { |c| [c.split("/").last, c] }`. Do not alter the row set — only order + label.
- **Patterns to follow:** the existing `cs-row-all` label block and muted-text CSS classes.
- **Test scenarios:**
  - Grouped keys `["admin/reports", "dashboard", "reports", "sessions"]` → ordered so `admin/reports` and `reports` are adjacent (assert relative order, exact base-resource grouping).
  - Row count and set unchanged vs `@grouped.keys` (no drop/dup — guards R6).
  - A namespaced row renders its namespace hint; a top-level row does not.
  - Enforcement is untouched: a scoped grant on `reports#destroy` does not imply `admin/reports#destroy` (cross-check via existing resolver test coverage; no new enforcement assertion needed here, note in Verification).
- **Verification:** grid + integration tests green; ordering visibly co-locates namespaced siblings; `namespaced_key_drift_test.rb` still green (no key semantics changed).

### U4. Optional per-permission descriptions via i18n tooltips

- **Goal:** surface a host-supplied human description per permission as a tooltip, gracefully absent by default.
- **Requirements:** R7.
- **Dependencies:** U2 (renders in the same cell/disclosure markup).
- **Files:** `app/views/current_scope/roles/edit.html.erb` (or a small helper in `app/helpers/current_scope/` if lookup logic warrants extraction), `test/integration/role_grid_test.rb`, `test/dummy/config/locales/en.yml` (fixture translations for the test only).
- **Approach:** at render time, look up `I18n.t("current_scope.permissions.#{controller}.#{action}", default: nil)` for each rendered action (group columns can describe the group via `current_scope.permission_groups.#{label}`, optional). When present, add it as a `title` on the cell label / disclosure item; when nil, render exactly as today. Ponytail: a one-line `I18n.t(..., default: nil)` — no config flag, no engine locale file, no catalog change (KTD-4). If the same lookup is needed in two spots, extract one `permission_description(controller, action)` helper; otherwise inline.
- **Patterns to follow:** Rails i18n `default: nil` graceful-absence idiom; existing engine helper conventions.
- **Test scenarios:**
  - With a `current_scope.permissions.wizard.submit_step_one` translation defined in `test/dummy` locale → the corresponding checkbox/label renders `title="<that text>"`.
  - With no translation → no `title` attribute added, grid unchanged (R7 graceful-absence).
  - Missing controller/action key never raises (default: nil).
- **Verification:** integration test green with and without a translation present; no engine locale file shipped (host-supplied only).

### U5. Config knob + documentation

- **Goal:** add `config.permission_grid_fold_custom_actions` (default true) and document all four enhancements honestly, including the upgrade note.
- **Requirements:** R4, R8 (and the doc mandate).
- **Dependencies:** U1–U4.
- **Files:** `lib/current_scope/configuration.rb`, `test/configuration_test.rb`, `README.md`, `docs/` (config reference / upgrading note — match existing `docs/plans` siblings, e.g. the config-reference-sync and upgrading-01-02 docs).
- **Approach:** `attr_accessor :permission_grid_fold_custom_actions`, default `true` in `initialize`, documented next to `permission_grid_groups` (line 130) with the honest note that it changes the grid layout for custom-action-heavy apps and can be set false to restore the flat matrix. README "Permission grid" section: document the disclosure fold, group-header tooltips, namespace ordering, and the i18n description hook (`current_scope.permissions.<controller>.<action>`), with a short host recipe for descriptions. Add an upgrade note: the default grid layout changes (one-off columns now fold); set `permission_grid_fold_custom_actions = false` to keep the old layout / stable column counts.
- **Test scenarios:**
  - `permission_grid_fold_custom_actions` defaults to `true`; assignable and read back (config test).
- **Test expectation:** docs portion — none (documentation only); config portion covered above.
- **Verification:** config test green; README renders; upgrade note names the exact opt-out and the behavior change; RuboCop clean.

---

## Scope Boundaries

**In scope:** `PermissionGrid` column/row partitioning + `custom_actions_for`; the edit view disclosure, group-header tooltips, namespace ordering + hint, and i18n description tooltips; the `permission_grid_fold_custom_actions` config knob; grid CSS; tests; README/upgrade docs. **Presentation layer only.**

**Preserved deliberate design choices (NOT changed):** the route-derived, table-free catalog (`permission_catalog.rb`); the aligned-matrix escalation guard and partial-group round-trip (`permission_grid.rb:45-61`); opt-in SoD; the resolver decision order, purity, and fail-closed posture. None of these are touched.

### Deferred to Follow-Up Work

- Collapsible `admin/*` namespace **section headers** with rowspans/indent trees (KTD-5 ships a comparator + badge instead).
- A per-controller **detail view** ("edit just this controller's permissions") as an alternative to the inline disclosure — heavier, only if disclosures prove insufficient at extreme scale.
- Engine-owned permission **metadata store** (descriptions the engine ships/persists) — explicitly a catalog/data-model change, out of scope (KTD-4); today's i18n hook covers the need host-side.
- Search/filter over controllers within the grid (orthogonal scale aid).

**Explicit non-goals:** no change to enforcement, resolver, guard, catalog derivation, or the submitted-params contract; no new dependency; no JS framework (native `<details>`).

---

## Open Questions

- **Namespace ordering surprise (R6/KTD-5):** ordering by `[base_resource, full_path]` co-locates namespaced siblings but reorders the whole list (e.g. `dashboard`/`sessions` interleave differently). Accepted as the smallest fix that delivers the finding; confirm the maintainer prefers this over keeping the flat alphabetical order and *only* adding an indent/badge (which leaves siblings scattered). Documented as a non-breaking presentation change either way.
- **Fold threshold:** singleton = "routed by exactly one controller." Confirm a count-based threshold (e.g. "fold when >N one-off columns exist") is *not* wanted instead — the per-action singleton rule is simpler, deterministic, and directly targets sparseness; assumed here.
- **Description i18n key shape:** `current_scope.permissions.<controller>.<action>` assumed (dotted, controller path segments as nested keys). Confirm before first release vs a flat `"<controller>#<action>"` key — the nested form reads better in a locale file but namespaced controllers (`admin/reports`) need the `/` handled (likely nested or slash-safe key). Pin this in U4.

---

## Cross-issue coupling

- **#21 (`bypass_sod` ungrantable / permission_keys drop) — companion.** #38's fold relies on one-off cells emitting the identical `role[permission_keys][]` key that survives `PermissionGrid#expand` and the model's `permission_keys=` dedup/catalog filter. If #21 changes how ungrantable/unknown keys are dropped on save, U1/U2's round-trip assertions (R2) must be re-checked against that behavior — coordinate the `permission_keys=` contract so a folded checkbox and a #21 filter agree on what is grantable.
- **#26 (adoption guide) / config-reference docs — compose.** U5 adds `permission_grid_fold_custom_actions` to the config surface; land its reference entry in whatever config-reference doc #26/#010 establish rather than duplicating, so the grid-scale knob is documented once in the canonical place.
- No coupling to the SoD/denial-behavior cluster (#23/#24/#37/#39) — this issue is purely the grid presentation and touches none of the enforcement/denial seams.
