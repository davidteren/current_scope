---
title: Config Reference Sync — initializer + README - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/28
---

# Config Reference Sync — initializer + README

## Goal Capsule

- **Objective:** make the config surface documented in **both** directions. The generated initializer template is the de-facto config reference for most users; today it omits the two shipped break-glass knobs (`allow_sod_bypass`, `sod_bypass_permission`), and the README omits `subject_label` and `permission_grid_groups`, never enumerates the `excluded_controllers` defaults, and never mentions the `current_scope_searchable_scope` hook. Close both gaps and retire the README's false "everything lives in the initializer" claim.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `docs/ROADMAP.md`, the shipped `lib/current_scope/configuration.rb`). This is a **documentation-only** change. The engine invariants — resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **purity** (no writes, no per-decision state), and ambient `CurrentAttributes` context — are described, never altered. No `lib/` runtime code, no `app/` code, no resolver/Guard/catalog behavior is touched. The single non-`.md` edit is the generator **template** (`lib/generators/.../templates/initializer.rb`), which is emitted text, not executed engine logic.
- **Stop conditions:** stop and surface rather than guess if (a) documenting a knob would require asserting behavior the code doesn't actually have (e.g. claiming `permission_grid_groups` merges when it replaces — it replaces, verified at `configuration.rb:130,148-153`); (b) a "reference table" default disagrees with the live default in `initialize` (the code is the source of truth — copy from it, never from memory); or (c) writing the searchable-scope docs surfaces a real behavior question (indexed vs Ruby-scan fallback) that the `scopeable.rb` comment doesn't already answer.

---

## Product Contract

> **Product Contract preservation:** documentation-sync issue, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Finding verified against source in issue #28; the break-glass config landed via `docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`.

### Summary

The initializer template and the README each document config options the other doesn't. Add the two break-glass knobs (commented, default-showing) to the template; add a complete option / default / one-liner **reference table** to the README's existing Configuration section covering every knob (including `subject_label` and `permission_grid_groups`); enumerate the `excluded_controllers` defaults where they're currently invisible; add a loud note that assigning `permission_grid_groups` **replaces** the CRUD defaults (it does not merge); document the `current_scope_searchable_scope` hook in the README's Scopeable section; and fix the README sentence that claims everything lives in the initializer.

### Problem Frame

Options absent from the generated initializer effectively don't exist for the median user — they never read `configuration.rb`. So the v0.2 break-glass feature, though fully shipped and documented in the README's SoD prose, is invisible to anyone who scaffolded via the generator (`initializer.rb` has no `allow_sod_bypass` line). In the other direction, the README's Configuration section (`README.md:348-372`) prose-lists a subset of knobs and explicitly claims "everything lives in the initializer," yet never names `subject_label` or `permission_grid_groups`, never shows the `excluded_controllers` defaults a host is silently inheriting, and points at no hook for `current_scope_searchable_scope`. Two verified DX papercuts compound this: assigning a custom `permission_grid_groups` hash silently **widens** the grid (it replaces the CRUD folding rather than merging — `configuration.rb:130`), and there's no check-time action aliasing (grouping is grid-only). The first is a documentation gap this plan closes with a loud note; the second is an enhancement left to a sibling issue.

### Requirements

- **R1.** The generated initializer template documents `allow_sod_bypass` and `sod_bypass_permission` as commented knobs showing their real defaults (`false`, `"bypass_sod"`), with a one-line honest-framing pointer (break-glass, not SoD; see the README SoD section).
- **R2.** The template makes the `excluded_controllers` **defaults** visible (the five inherited regexps: `rails/`, `active_storage/`, `action_mailbox/`, `turbo/`, `current_scope/`) so a host reading the `+=` example knows what it's adding to.
- **R3.** The README's Configuration section carries a complete reference **table** — one row per config knob — with columns: option, default, one-line purpose. Every `attr_accessor`/`attr_reader` in `configuration.rb` appears exactly once; the shown defaults match `initialize`.
- **R4.** The table (or adjacent prose) explicitly covers `subject_label` and `permission_grid_groups`, which the README currently omits entirely.
- **R5.** A loud note states that assigning `permission_grid_groups` **replaces** the CRUD-folding defaults (it is not merged); to keep CRUD folding plus a custom group, the host must include the default pairs in the assigned hash. No behavior claim beyond what `configuration.rb:130,148-153` and `permission_grid.rb` actually do.
- **R6.** The README's Scopeable section documents the optional `current_scope_searchable_scope(term)` class method — what it's for (indexed SQL search vs the default first-500-rows Ruby scan), its signature (term → `ActiveRecord::Relation`), and that no default is provided.
- **R7.** The false/overreaching README sentence "Everything lives in `config/initializers/current_scope.rb`" is corrected to something true (the initializer is where config lives, and the table below is the full reference — but model-side hooks such as `current_scope_label` and `current_scope_searchable_scope` live on host models, not the initializer). Phrase the correction non-exhaustively ("such as", not "two hooks"): host models also carry `current_scope_initiator` and `current_scope_sod_bypassed?` (resolver.rb:15,19), so a fixed count would trade one overreaching claim for a subtly false one.
- **R8.** No runtime behavior change. Zero edits under `lib/current_scope/`, `app/`. The only non-`.md` file touched is the generator template; a fresh `rails g current_scope:install` still produces a valid, loadable initializer.

---

## Key Technical Decisions

- **KTD-1 — README inline table, not a new `docs/reference/configuration.md`.** The issue offers either. The gem keeps its whole config story in the README (there is no `docs/reference/` dir today), and the very sentence being corrected promises a single place to look. Splitting the reference into a new file would create a second source that drifts from the initializer — the exact failure mode this issue is about. Put the table in the **existing** README Configuration section, adjacent to the prose that already frames it. (Ponytail: one table in the file people already read beats a new docs tree to maintain.)
- **KTD-2 — Defaults are copied from `configuration.rb#initialize`, verbatim, at write time.** The table's value is only as good as its agreement with the code. Every default cell is transcribed from `initialize` (`user_method` `:current_user`, `sod_actions` `[]`, `sod_identity` `:either`, `allow_sod_bypass` `false`, `sod_bypass_permission` `"bypass_sod"`, `allow_mutations_while_impersonating` `false`, `excluded_controllers` the five regexps, `parent_controller` `"::ApplicationController"`, `subject_class` `"User"`, `subject_label` `nil`, `audit` `true`, `warn_on_nil_sod_record` `false`, `permission_grid_groups` the CRUD hash). Not from memory, not from the template comments (which can themselves drift).
- **KTD-3 — Document `permission_grid_groups` as replace-on-assign; do NOT add a merge helper here.** The verified finding (issue #28, `02_custom_actions`) is a **docs-gap** verdict, not a bug: the grid grouping works correctly, it just replaces rather than merges. The smallest correct fix is the loud note (R5). Exposing the default hash as a public constant (e.g. `DEFAULT_PERMISSION_GRID_GROUPS`) so hosts can splat-merge it is a real ergonomic improvement but a **code change with an API-surface commitment** — out of scope for a docs sync, deferred to the sibling enhancement (see Cross-issue coupling). Documenting the replace semantics is what unblocks users today.
- **KTD-4 — No prod env-gate or behavior text invented for break-glass in the template.** The template comment for `allow_sod_bypass` mirrors the honest framing already in `configuration.rb:74-96` and the README SoD section: default-off, privilege-gated, audited, and — unlike `allow_mutations_while_impersonating` — **no** production env-gate. The template must not imply a gate that doesn't exist. (Preserves least-astonishment: the same knob reads the same everywhere.)

*No decision here risks resolver purity or the fail-closed posture — this plan writes prose and commented template lines, it changes no decision path.*

---

## Implementation Units

### U1. Initializer template — add break-glass knobs and surface exclusion defaults

- **Goal:** the generated `config/initializers/current_scope.rb` documents every knob a scaffolded host might set, including the two break-glass options, and shows the `excluded_controllers` defaults it's inheriting.
- **Requirements:** R1, R2, R8.
- **Dependencies:** none.
- **Files:** `lib/generators/current_scope/install/templates/initializer.rb`, `test/generators/install_generator_test.rb` (add/extend — the engine's generator test; if none exists, a minimal one under `test/generators/`).
- **Approach:** insert a commented break-glass block near the SoD block (after the `sod_actions` comment, before `audit`), showing `# config.allow_sod_bypass = false` and `# config.sod_bypass_permission = "bypass_sod"` with a 2-3 line comment that (a) names it break-glass (audited policy override, not SoD), (b) points at the README "Break-glass override" subsection, (c) notes it needs the host `current_scope_sod_bypassed?` hook. Copy the framing tone from the `sod_actions` and `audit` comments already in the template. For R2, extend the existing `excluded_controllers` comment to enumerate the five inherited defaults before the `+=` example, e.g.:
  ```ruby
  # Controller paths (regexps) excluded from the permission grid. Defaults already
  # exclude: rails/, active_storage/, action_mailbox/, turbo/, current_scope/.
  # Add your own (note the += — replace with = only to override the defaults):
  # config.excluded_controllers += [%r{\Awebhooks/}]
  ```
  Keep every added line commented so the emitted initializer stays behavior-neutral (R8).
- **Patterns to follow:** the existing comment style in `initializer.rb` (leading `# config.x = default`, grouped blocks with `--- Section ---` rules, cross-refs to README section names). Match the impersonation block's layering-comment density.
- **Test scenarios:**
  - **Generator emits valid config:** running the install generator produces `config/initializers/current_scope.rb` that loads without error and contains the strings `allow_sod_bypass`, `sod_bypass_permission`, and the five exclusion default tokens (`rails/`, `active_storage/`, `action_mailbox/`, `turbo/`, `current_scope/`). input: `rails g current_scope:install` → expected: file present, `assert_file` matches those substrings.
  - **Behavior-neutral:** every added `config.` line is commented, so a freshly generated initializer changes no default — assert the generated file has no *uncommented* `allow_sod_bypass`/`sod_bypass_permission` assignment.
- **Verification:** generator test green; a scratch `rails g current_scope:install` in `test/dummy` (or the generator test's captured output) yields a loadable initializer naming the new knobs; RuboCop clean on the template if it's linted.

---

### U2. README Configuration section — complete reference table + grid-groups note + fix the false claim

- **Goal:** the README's Configuration section is a complete, correct reference for every config knob, names the two currently-missing options, warns about the grid-groups replace semantics, and no longer claims the initializer holds *everything*.
- **Requirements:** R3, R4, R5, R7.
- **Dependencies:** U1 (so the table and the template agree on the break-glass knobs; both land together).
- **Files:** `README.md` (the `### Configuration` section, currently ~lines 348-372).
- **Approach:** add a markdown table after the section's opening prose with one row per knob, columns **Option | Default | Purpose**, transcribing defaults from `configuration.rb#initialize` per KTD-2. Rows, in `initialize` order: `user_method`, `actor_method`, `sod_actions`, `sod_identity`, `allow_sod_bypass`, `sod_bypass_permission`, `allow_mutations_while_impersonating`, `excluded_controllers`, `parent_controller`, `subject_class`, `subject_label`, `audit`, `warn_on_nil_sod_record`, `permission_grid_groups`. For rows already covered in depth elsewhere (impersonation trio, SoD, audit, break-glass) keep the Purpose cell one line and link to the section that owns the detail. Directly below the table, add a short **`permission_grid_groups` — assignment replaces, not merges** note (R5): assigning a custom hash drops the CRUD folding, so ticking gets *wider*, not narrower; to keep CRUD folding plus a custom group, include the default pairs (`"read" => %w[index show]`, etc.) in the assigned hash. Then edit the opening sentence (R7): replace "Everything lives in `config/initializers/current_scope.rb`" with wording that says the initializer is where **configuration** lives (the table below is the full reference), while host **model** hooks such as `current_scope_label` and `current_scope_searchable_scope` (U3) live on your models, not the initializer. Keep the phrasing non-exhaustive ("such as") — models can also define `current_scope_initiator` and `current_scope_sod_bypassed?`, so don't assert a fixed hook count.
- **Patterns to follow:** existing README table/heading conventions; the cross-linking style already used (`[Impersonation](#impersonation-act-as)`, `[Separation of duties](#separation-of-duties-opt-in)`). Keep the honest, plain-language tone the SoD/break-glass sections set.
- **Test scenarios:** Test expectation: none — documentation only. (Verification is human review + a link/consistency check, below.)
- **Verification:** every `attr_accessor`/`attr_reader` in `configuration.rb` has exactly one table row; each default cell matches `initialize` (diff the two by eye or a scratch script that greps the accessors and asserts each name appears once in the table); `subject_label` and `permission_grid_groups` both present; the replace-not-merge note present; the "everything lives in the initializer" sentence gone; all intra-doc anchor links resolve.

---

### U3. README Scopeable section — document `current_scope_searchable_scope`

- **Goal:** hosts know the picker's search hook exists and how to define it, instead of finding it only in the `scopeable.rb` source comment or the CHANGELOG.
- **Requirements:** R6, R7 (the "model hooks live on the model" half).
- **Dependencies:** none (independent of U1/U2; groups with U2 as the README changeset).
- **Files:** `README.md` (the `### Scopeable models` section, ~lines 223-239).
- **Approach:** after the existing `current_scope_label` example, add a short paragraph + code block for the **optional** `self.current_scope_searchable_scope(term)` class method: without it the picker scans the first ~500 rows and filters `current_scope_label` in Ruby (no backing column); define it to search via indexed SQL, receiving the query term and returning an `ActiveRecord::Relation`; no default is shipped because only the host knows which column is indexed. Lift the example near-verbatim from the `scopeable.rb:24-36` comment (`where("name ILIKE ?", "%#{term}%")`) so source and docs agree. Frame it as browse/search sugar — like `current_scope_label`, it does not gate anything.
- **Patterns to follow:** the adjacent `current_scope_label` doc block's structure (one-liner + fenced Ruby example + a "this is browse-only, not access control" caveat).
- **Test scenarios:** Test expectation: none — documentation only.
- **Verification:** the README example compiles as valid Ruby (define-time), matches the `scopeable.rb` comment's signature (`term` → `Relation`), and states the Ruby-scan fallback and "no default" facts; a reader can wire indexed search without opening the gem source.

---

## Scope Boundaries

**In scope:** the initializer template edit (commented break-glass knobs + enumerated exclusion defaults), the README Configuration reference table, the `permission_grid_groups` replace-on-assign note, the corrected "everything lives in the initializer" sentence, and the README Scopeable searchable-scope docs. Documentation and generator-template only.

**Explicit non-goals (preserve deliberate design):**
- No change to `permission_grid_groups` **behavior** — replace-on-assign is documented, not "fixed." The route-derived catalog and grid-only grouping semantics stay as designed.
- No new check-time permission aliasing/merging — the resolver stays exact-match (`resolver.rb:93-96`), grouping stays a grid save-path concern (`permission_grid.rb`). That's an enhancement, not this docs sync.
- No new `docs/reference/` tree (KTD-1) — the reference lives in the README.
- No engine/runtime edits; break-glass behavior itself already shipped (`2026-07-12-001` plan).

### Deferred to Follow-Up Work

- **Expose a mergeable default for `permission_grid_groups`** — publish the default hash as a public constant (e.g. `CurrentScope::Configuration::DEFAULT_PERMISSION_GRID_GROUPS`) so a host can `config.permission_grid_groups = DEFAULT.merge("workflow" => [...])` instead of hand-copying CRUD pairs. Real ergonomics win, but a code + public-API change; belongs with the grid-groups enhancement issue, not a docs sync.
- **Check-time action aliasing** (`config.permission_aliases`) — the `02_custom_actions` enhancement finding. Would let the resolver treat `moderate` as `approve+reject`; touches the resolver's exact-match core and SoD keying, so it needs its own plan and a hard purity/fail-closed review. Out of scope here.

## Open Questions

- **Reference table placement vs the initializer as source of truth.** KTD-1 puts the table in the README. If the maintainer would rather the table live *as generated comments* and have the README simply say "read your generated initializer," that's a viable alternative that avoids any drift by construction — but it makes the web README a weaker reference. Assumed: README table. Flip if preferred.
- **Should the template's break-glass block be commented-out only, or also cross-link the host `current_scope_sod_bypassed?` recipe inline?** Assumed: commented knobs + a one-line pointer to the README "Break-glass override" recipe, to keep the generated file scannable rather than duplicating the recipe.

## Cross-issue coupling

- **Companion to the shipped break-glass feature** (`docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`, its U4 added the README SoD subsection). That plan documented break-glass in the README but did **not** update the generator template — this issue (#28) closes exactly that residual gap. The plans compose: #28 finishes the config-surface documentation the break-glass plan started.
- **Sibling to the two `02_custom_actions` enhancement findings** (tracked in the task as the #45/#46 enhancement pair). This docs issue documents `permission_grid_groups` *as it behaves today* (replace-on-assign, grid-only) — U2's loud note. The enhancement issues change that behavior (a mergeable default constant; check-time `permission_aliases`). Composition rule: land this docs note first so today's users are unblocked; the enhancement PRs then update the same README table row and note when/if they ship, rather than the docs waiting on the code. If the enhancement issues are the referenced #45/#46, they should link back to U2 so the doc and behavior land in step.
