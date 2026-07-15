---
title: Adopting current_scope in an Existing App — Guide - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/26
---

# Adopting current_scope in an Existing App — Guide - Plan

## Goal Capsule

- **Objective:** write `docs/guides/adopting-in-an-existing-app.md` — the missing retrofit guide for the majority case (adding the gem to an app that already has authentication, controllers, and maybe Pundit). Cover the four verified traps from the finding: (1) `Guard`'s gate registers at include time, so an auth `before_action` declared *below* the includes runs second and anonymous users get a blank 403 instead of a login redirect; (2) Devise (and any engine) controllers descend from `ApplicationController`, get gated, and brick sign-in unless excluded **and** skipped; (3) `skip_before_action :current_scope_check!` silently **inherits into subclasses** — a partial escape hatch that fails *open* across a controller tree; (4) hybrid HTML+API apps must grant `items#index` and `api/v1/items#index` separately. Add an incremental-rollout path (Guard on one namespace's base + `GatingTripwire` on `ApplicationController` to inventory ungated surface, then expand). Plus a small `README.md` pointer and a one-line generator next-step so a fresh installer finds the guide before hitting the traps.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `docs/ROADMAP.md`, `resources/DESIGN.md`). The engine invariants are **immutable and NOT touched by this issue**: resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **purity** (no writes / no per-decision state), and the ambient `CurrentAttributes` context. This is a **docs-plus-one-generator-string** change. No behavior is altered. Every trap the guide documents is *current, correct, deliberate* engine behavior — the guide teaches the reader to work with it, it does not argue for changing it.
- **Stop conditions — surface rather than guess if:**
  - (a) writing an honest recipe would require *changing* engine behavior to make the prose true (e.g. if the Devise recipe can't be made to work with the shipped `excluded_controllers` + `skip_before_action` seams — it can, verified below; but if a reviewer finds it can't, that is a code issue, not this docs issue);
  - (b) the skip-inheritance guidance would contradict Rails' own documented `skip_before_action` inheritance semantics (it must describe them faithfully, not wish them away);
  - (c) the generator string change would drift from what `show_next_steps` can say without new dependencies.

---

## Product Contract

> **Product Contract preservation:** documentation issue, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded entirely in the filed finding (`issue #26`) and re-verified against `lib/current_scope/guard.rb`, `lib/current_scope/gating_tripwire.rb`, `lib/current_scope/permission_catalog.rb`, `lib/current_scope/resolver.rb`, `lib/generators/current_scope/install/install_generator.rb`, and `README.md` on 2026-07-15.

### Summary

Give the retrofit audience one page they can follow start to finish. Greenfield installs are the minority; the README's Installation section shows the two-include snippet as if `ApplicationController` were empty, but in a real app it already has `before_action :require_login`, Devise routes, an existing Pundit layer, and a hybrid HTML+API surface. Each of the four traps presents as a confusing symptom far from its cause (the gem "broke routing", "bricked login", "a subclass is ungated", "the API 403s but the page loads"). The guide names each trap, shows the symptom, explains the mechanism in one or two sentences grounded in the actual code, and gives the copy-able fix. It ends with a staged rollout so a large app can adopt the gate one namespace at a time instead of flipping fail-closed everywhere on day one.

### Problem Frame

Four verified traps, all hit within minutes in the legacy-scenario test apps, none documented:

1. **Include-order vs the host's auth callback (major, bug-shaped, docs-gap).** `Guard`'s `before_action :current_scope_check!` is registered in `included do` (`guard.rb:27-29`), so it runs in include order. If `require_login` is declared *below* `include CurrentScope::Guard`, the gate runs first, sees a nil subject, and the resolver returns `[false, :no_grant]` (`resolver.rb:34`) — a blank 403 instead of the login redirect the app promised. The README install snippet (`README.md:83-88`) shows the includes at the top of the class with zero ordering guidance relative to existing host callbacks.
2. **Devise / engine controllers get gated and brick sign-in (major, dx, docs-gap).** Devise's controllers inherit `ApplicationController`, so they inherit `Guard`. A signed-out user hitting `/users/sign_in` is denied before Devise ever renders. The fix is two knobs that must agree: `excluded_controllers` (keep Devise out of the catalog) **and** `skip_before_action :current_scope_check!` on the Devise controllers (because an excluded-but-gated controller makes Guard *raise* — `guard.rb:41-46`). The README documents each knob in isolation but never the Devise recipe.
3. **`skip_before_action` inherits into subclasses — fails OPEN (major, security, docs-gap).** `skip_before_action :current_scope_check!, only: [:dashboard]` on `LegacyController` is inherited by `LegacySubController < LegacyController`, so `legacy_sub#dashboard` is ungated for any signed-in user — while the grid still shows it as a grantable, apparently-enforced permission. This is vanilla Rails callback-inheritance, but in an authorization gem the fail direction is *open*; `GatingTripwire` on the base **does** trip on it in dev/test (its `after_action` sees `@current_scope_checked` never set and raises), yet the grid still shows the action as enforced and there is no production runtime net — the gap #37 addresses. The README's skip recipe (`README.md:90-96`) carries no inheritance warning.
4. **Hybrid HTML+API dual-grant burden (minor, dx, docs-gap).** `controller#action` *is* the permission (`guard.rb:37`), one key per full controller path with no aliasing (`permission_catalog.rb:22-31`). So `items#index` does not imply `api/v1/items#index`; a role granting only the former yields 200 on `/items` and 403 on `/api/v1/items`. Correct by design, but the dual-grant consequence is undocumented.

### Requirements

- **R1.** The guide documents the **include-order rule**: the host's authentication `before_action` (or `prepend_before_action`) must run *before* `current_scope_check!`, and shows the two correct orderings (declare auth above the includes, or `prepend_before_action`). It states the symptom (anonymous user gets a blank 403 + `X-Current-Scope-Reason: no_grant` instead of a login redirect) and the one-line mechanism (the gate is registered at include time and denies nil subjects).
- **R2.** The guide gives a **verbatim, copy-able Devise recipe**: add the Devise controller paths to `config.excluded_controllers` AND `skip_before_action :current_scope_check!` on those controllers, explaining why *both* are needed (excluded-but-gated raises; skip-without-exclude leaves dead grid rows). Generalizes to any mounted engine whose controllers descend from `ApplicationController`.
- **R3.** The guide documents **coexisting with / replacing Pundit**: run both during migration (CurrentScope gates at the controller boundary, Pundit stays for record policies until ported), and the end-state where `allowed_to?` / `scope_for` replace `authorize` / `policy_scope`. No code change — guidance and a migration order only.
- **R4.** The guide carries a **skip-inheritance warning** (the security-critical one): `skip_before_action` inherits into every subclass and fails *open*. Prescribe the safe patterns — prefer per-controller skips on **leaf** controllers, or re-assert the gate in the subclass (`before_action :current_scope_check!`). Note the automated defense: `GatingTripwire` on the Guard'd base (per R6) **does** trip on the inherited skip in dev/test — running the suite with it on is the concrete detection step — but it is a dev/test aid only, so the residual production gap (and the lying grid) is #37's scope.
- **R5.** The guide documents the **namespaced / hybrid dual-grant** reality: `items#index` and `api/v1/items#index` are independent keys that must be granted in tandem; cross-links the existing README "namespaced/custom-named controllers" foot-gun for `allowed_to?` derivation.
- **R6.** The guide gives an **incremental rollout path**: (a) `GatingTripwire` on `ApplicationController` (or an API base) in dev/test to *inventory* the ungated surface without enforcing; (b) turn on `Guard` for one namespace's base controller first; (c) expand namespace by namespace; (d) only broaden `excluded_controllers` deliberately. Grounded in the shipped `GatingTripwire` API (`gating_tripwire.rb`), including its known blind spot (an `after_action` can't see an action that renders from a halted `before_action`).
- **R7.** `README.md` links to the new guide from the Installation section (one sentence, near the existing skip recipe), so a reader mid-install finds it.
- **R8.** `install_generator.rb#show_next_steps` gains one line pointing at the guide for existing apps ("Adopting into an app that already has auth? See docs/guides/adopting-in-an-existing-app.md").

---

## Key Technical Decisions

- **KTD-1 — Docs + one generator string only; zero engine behavior change.** Every trap is current, correct, deliberate behavior. Include-order sensitivity is intrinsic to `before_action` registration; skip-inheritance is Rails' own semantics; the dual-grant is the route-derived-catalog design the gem is built on (`permission_catalog.rb`). The honest fix is to *teach* these, not to file down the seams. Anything that tempts a code change (e.g. "make skip not inherit", "alias HTML and API keys") is out of scope and, if genuinely warranted, belongs in a separate issue — flag, don't smuggle under a `docs` label.
- **KTD-2 — New `docs/guides/` directory, not a README section.** The retrofit material is long (six sub-topics, three recipes, a rollout ladder) and would swamp the README's quickstart. `docs/` already holds `ROADMAP.md`, `RESEARCH.md`, `READINESS-AUDIT.md`; a `guides/` subdir is the natural home and matches the "deeper walkthrough lives below the quickstart" house pattern. The README gets a one-line pointer (R7), not the content.
- **KTD-3 — Devise recipe = exclude AND skip, and say why both.** The shipped seams already make this work: `excluded_controllers` removes the Devise paths from the catalog (`permission_catalog.rb:27`) so they aren't dead grid rows, and `skip_before_action :current_scope_check!` stops Guard from *raising* on the now-uncatalogued controller (`guard.rb:41-46`). Neither alone is correct: exclude-only → Guard raises `ConfigurationError` on sign-in; skip-only → sign-in works but Devise actions litter the grid as ungrantable no-op rows (the finding's third symptom, cross-issue with #37). The guide prescribes both together and explains the two-knobs-must-agree relationship explicitly.
- **KTD-4 — Skip-inheritance is framed as the guide's headline SECURITY warning, not a footnote.** It is the one trap that fails *open*, and `GatingTripwire` (included on the Guard'd base per R6) **is** the automated defense that catches it in dev/test: `skip_before_action :current_scope_check!` skips only Guard's before_action, not the tripwire's separate `after_action :current_scope_verify_gated!`, which fires on the inherited-skip action, finds `@current_scope_checked` never set (`gating_tripwire.rb:44` returns early *only* when it IS set — it isn't, because the skipped gate never reached `guard.rb:36`), and raises. So the guide's detection step is prescriptive: run the suite with the tripwire on the base. The residual gap is real but narrower — the tripwire is a dev/test aid only (no production runtime net) and the grid still shows the action as enforced; that runtime gap is what #37 (report-only mode) closes. The safe patterns (leaf-only skips, or re-assert `before_action :current_scope_check!` in the subclass) are prescriptive, with the "prefer leaf" default called out.
- **KTD-5 — Rollout ladder leans on the *existing* `GatingTripwire`, not a new inventory tool.** The finding asks for "inventory the ungated surface then expand." `GatingTripwire` already does exactly this in dev/test (raises after any action that didn't run the gate). The guide documents using it as the inventory step, including its documented blind spot (halted-before_action renders escape it — `gating_tripwire.rb:20-23`). No new code. If a non-raising report-only inventory is wanted, that's #37's job — cross-linked, not duplicated.

---

## Implementation Units

### U1. Write `docs/guides/adopting-in-an-existing-app.md`

- **Goal:** the retrofit guide — six sub-topics and three recipes, each: symptom → one-sentence mechanism (grounded in a cited gem line) → copy-able fix.
- **Requirements:** R1, R2, R3, R4, R5, R6.
- **Dependencies:** none.
- **Files:** `docs/guides/adopting-in-an-existing-app.md` (new).
- **Approach:** structure the page as:
  1. **When to read this** — one paragraph: you have an existing app with auth and controllers; here are the four traps and where they bite.
  2. **Include order relative to authentication (R1).** Symptom: signed-out `GET /legacy/stats` returns a blank 403 with `X-Current-Scope-Reason: no_grant` instead of redirecting to sign-in. Mechanism: `Guard` registers `before_action :current_scope_check!` at include time (`guard.rb:27-29`); a `require_login` declared *below* the includes runs second, so the gate denies the nil subject first (`resolver.rb:34`). Fix: put the auth callback *above* the two includes, or use `prepend_before_action :require_login`. Show both, correct, side by side. Cross-link the denial-behavior guide (#24) for what the 403 renders.
  3. **Devise & mounted engines (R2, KTD-3).** Verbatim recipe: add the Devise controller path regexes to `config.excluded_controllers`, AND `skip_before_action :current_scope_check!` on the Devise controllers (via a Devise controller subclass or `Devise::SessionsController` reopening). Explain the two-knobs rule: exclude-only raises (`guard.rb:41-46`), skip-only leaves dead grid rows (#37). Generalize to any engine (e.g. mounted admin engines) whose controllers descend from `ApplicationController`.
  4. **Coexisting with / replacing Pundit (R3).** Migration order: (a) add `Context` + `Guard`, keep Pundit's `authorize`/`policy_scope` running; the gate is the outer boundary, Pundit stays for record policies. (b) Port controller-boundary checks to the auto-derived permission grid; port `policy_scope` calls to `scope_for`. (c) Remove Pundit once every policy is expressed as roles/scoped-roles. Note the semantic difference: Pundit is code-defined policy, CurrentScope is data-defined-and-editable — the whole reason to migrate.
  5. **The skip-inheritance trap — READ THIS (R4, KTD-4).** Headline security warning. Symptom: `skip_before_action :current_scope_check!, only: [:dashboard]` on a base controller silently ungates `subclass#dashboard` for any signed-in user; a roleless user gets 200 where they should get 403. Mechanism: Rails inherits the skip; the gate never runs on `subclass#dashboard`, so the grid still shows the action as enforced (the grid lies). Detection: `GatingTripwire` on the base (per the rollout ladder) **does** catch this in dev/test — its `after_action` finds `@current_scope_checked` never set and raises — so run the suite with the tripwire on to surface it; the residual runtime gap (tripwire is dev/test only) is #37's scope. Safe patterns: **prefer skips on leaf controllers**; if a base must skip, re-assert `before_action :current_scope_check!` in each subclass that should stay gated. Cross-link #37.
  6. **Namespaced & hybrid HTML+API grants (R5).** `controller#action` is the permission (`guard.rb:37`); `items#index` and `api/v1/items#index` are independent keys with no aliasing (`permission_catalog.rb:22-31`). A role must grant both to serve the same resource over HTML and API. Cross-link the README "namespaced/custom-named controllers" note for the parallel `allowed_to?` derivation foot-gun.
  7. **Incremental rollout (R6, KTD-5).** The ladder: (a) *inventory* — `include CurrentScope::GatingTripwire` on `ApplicationController` (and any non-Guard API base) in dev/test to find every ungated action, marking genuinely-public ones with `current_scope_skip_tripwire!`; note the halted-before_action blind spot (`gating_tripwire.rb:20-23`). (b) *gate one namespace* — include `Guard` on one namespace's base controller, seed grants, verify. (c) *expand* namespace by namespace. (d) broaden `excluded_controllers` only deliberately. Note the day-one reality (borrow from #24): once `Guard` is on, existing controller tests go red until grants are seeded.
- **Patterns to follow:** the README's voice — symptom-then-mechanism-then-fix, blockquote callouts for foot-guns, fenced Ruby for recipes. Match the "residual foot-gun" blockquote style already in `README.md`'s "Residual foot-gun — namespaced/custom-named controllers" note. Repo-relative links only.
- **Test scenarios:** Test expectation: none — documentation only. Correctness is verified by every recipe matching shipped behavior (see Verification); the four symptoms already have green repro tests in the `current_scope_test_scenarios` sandbox (`legacy_retrofit_test.rb`, `partial_skip_test.rb`, `api_guard_test.rb`), which are the ground truth the prose must not contradict.
- **Verification:** each cited line number resolves to the described behavior in the current source; the Devise recipe's exclude+skip combination is consistent with `guard.rb:41-46` (raise-on-excluded-but-gated) and `permission_catalog.rb:27` (excluded → not in catalog); the rollout ladder uses only the shipped `GatingTripwire` API. A second reader can follow each recipe without touching engine code.

### U2. README pointer to the guide

- **Goal:** a reader mid-install finds the retrofit guide before hitting a trap.
- **Requirements:** R7.
- **Dependencies:** U1 (the link target must exist).
- **Files:** `README.md`.
- **Approach:** add one sentence in the Installation section, right after the skip recipe (`README.md:90-96`), e.g.: *"Adding CurrentScope to an app that already has authentication, Devise, or Pundit? Read [Adopting in an existing app](docs/guides/adopting-in-an-existing-app.md) first — include order relative to your auth callback, the Devise recipe, the skip-inheritance trap, and an incremental rollout path."* Repo-relative link.
- **Patterns to follow:** the existing cross-link style in the README (e.g. the Design notes bullets, `README.md:568-575`).
- **Test scenarios:** Test expectation: none — documentation only.
- **Verification:** link resolves to `docs/guides/adopting-in-an-existing-app.md`; the sentence sits in the Installation flow, not buried at the end.

### U3. Generator next-step pointer

- **Goal:** a fresh installer sees the guide reference in the terminal output.
- **Requirements:** R8.
- **Dependencies:** U1.
- **Files:** `lib/generators/current_scope/install/install_generator.rb`, `test/` generator test if one exists for `show_next_steps` (add one only if the file already has generator coverage — otherwise Test expectation: none).
- **Approach:** add one line to the `show_next_steps` heredoc (`install_generator.rb:14-30`), after step 2 (the includes), e.g.: *"Adopting into an app that already has auth (Devise/Pundit)? See docs/guides/adopting-in-an-existing-app.md — include order matters."* Plain string, no new dependency. This is the smallest change that puts the guide in front of the person who most needs it (they're editing `ApplicationController` right now).
- **Patterns to follow:** the existing numbered-step heredoc voice in `show_next_steps`. Keep it one line; the generator output is already dense.
- **Test scenarios:** if a generator test exists, assert the output includes the guide path. Otherwise Test expectation: none — a one-line `say` string with no logic (ponytail: a branch-free string append needs no test).
- **Verification:** `bin/rails generate current_scope:install` output mentions the guide path; RuboCop clean.

---

## Scope Boundaries

**In scope:** the new `docs/guides/adopting-in-an-existing-app.md`, a one-sentence README pointer, and a one-line generator next-step. Documentation of *current* behavior only.

**Explicit non-goals (preserve deliberate design):**
- Not changing `skip_before_action` inheritance (Rails semantics; the guide teaches working with it).
- Not adding key aliasing or grouping for hybrid HTML+API (`items#index` ≠ `api/v1/items#index` is the route-derived-catalog design — `permission_catalog.rb`). The guide documents the dual-grant; it does not introduce aliasing.
- Not building a new inventory/report tool — the rollout ladder uses the shipped `GatingTripwire`. A non-raising report-only inventory is #37's scope.
- Not shipping the Devise controllers or a Pundit shim — the guide gives recipes the host applies, exactly as the Impersonation section ships plumbing + recipe, not endpoints.

### Deferred to Follow-Up Work

- **UI marking of skipped/ungated controllers in the grid** (the finding's third symptom — dead grantable rows for skipped controllers). That is a management-UI change, tracked by #37 (report-only mode); the guide only *warns* about it and points readers at pairing `skip_before_action` with `excluded_controllers`.
- **A generator flag to scaffold the Devise exclusion** automatically — nice, but speculative; the recipe is a five-line paste. Add only if adopters ask.

---

## Open Questions

- **Devise controller path regexes — exact list.** The recipe should show the common Devise paths (`devise/sessions`, `devise/registrations`, `devise/passwords`, etc., or a `%r{^devise/}` catch-all, plus the host's own `users/*` overrides). Confirm whether to show the catch-all regex (simpler, but also excludes any host controller under a `devise/` namespace — unlikely) or the explicit list. Leaning catch-all with a note.
- **Guide cross-link density.** The guide naturally references the denial-behavior guide (#24), the report-only/grid-marking work (#37), and the README foot-gun notes. Confirm the maintainer wants inline cross-links now (some targets may not be merged yet) vs. a "see also" footer that's easy to keep from dangling.

---

## Cross-issue coupling

- **#24 (denial-behavior docs, plan `2026-07-15-006`).** Trap #1 (blank 403 instead of login redirect) is the *retrofit face* of the same blank-403 that #24 documents in general. The adoption guide should link to #24's "When access is denied" section for what the 403 renders and how to override it, rather than re-explaining the rescue/header mechanics. Compose: #24 owns *what a denial does*; #26 owns *why an anonymous request denies instead of redirects, and how to order callbacks so it redirects*.
- **#37 (report-only mode).** Trap #3 (skip-inheritance fails open) and the finding's third symptom (skipped controllers still render as grantable grid rows) both point at the same gap: today the only way to *see* the ungated surface is `GatingTripwire` (raises) or reading the grid (which lies). #37's report-only inventory would surface it at runtime without enforcing. The guide's rollout ladder (R6) should cross-link #37 as the "when you want a non-raising inventory" upgrade, and the skip-inheritance warning (R4) should note #37 as the runtime safety net. Plans compose: #26 is the human-readable guidance that ships now; #37 is the tooling that makes the guidance enforceable later.
