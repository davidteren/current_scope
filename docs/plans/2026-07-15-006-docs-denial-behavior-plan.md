---
title: Document Denial Behavior End-to-End - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/24
---

# Document Denial Behavior End-to-End - Plan

## Goal Capsule

- **Objective:** close the single largest documentation gap in the gem — nothing in the README explains what a denial *renders*, how to override it, or why a host's own `rescue_from` can silently break it. Add a "When access is denied" section right after Installation covering the auto-installed rescue, the blank 403, the `X-Current-Scope-Reason` header, the declaration-order-sensitive override seam (including the `rescue_from StandardError` shadowing trap), a branded-HTML recipe, a JSON/API recipe, and an install-time warning that existing controller tests will 403 until grants are seeded. Pair it with a tiny generator `show_next_steps` edit so a fresh installer sees the warning before the test suite goes red.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `docs/ROADMAP.md`, `resources/DESIGN.md` if present). The engine invariants are **immutable and NOT touched by this issue**: resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver PURITY (no writes / no per-decision state), and the ambient `CurrentAttributes` context. This is a **docs-plus-generator-string** change. The one behavior-bearing method in the denial path — `MutationGuard#current_scope_denied` — is **not changed by THIS plan**. It has, however, already been changed by **PR #55 (#23)**: it now writes the reason header and delegates the body to an overridable `current_scope_render_denied(reason)`. We document the current behavior faithfully; we do not "fix" it here.
- **Stop conditions — surface rather than guess if:**
  - (a) faithfully documenting the current default would require *changing* `current_scope_denied` to make the prose true (it must not — that is #39's job now; **#23 is CLOSED, shipped in PR #55**, and it already changed the default. See the reality check below before writing a word);
  - (b) the recommended override recipe would tell hosts to register a handler in a way that itself breaks the mutation-guard or SoD paths;
  - (c) the generator string change would drift from what `show_next_steps` can actually say without new dependencies.

> ### ⚠ Reality check before implementing — this plan predates the code it documents
>
> Drafted on the morning of 2026-07-15. **PR #55 (issue #23) merged that afternoon and changed the denial contract this plan describes.** Four of its statements below were true when written and are now false:
>
> | This plan says | Reality |
> |---|---|
> | "the three denial reason codes" (R1) | **four** — `:not_full_access` was added |
> | a denial "renders an empty body" | true for **host** denials only; the engine's console now renders an explanation page |
> | `current_scope_denied` is "deliberately left unchanged" (KTD-1) | it changed — it delegates the body to `current_scope_render_denied(reason)` |
> | defers the default's correctness to "#23/#39's job" | **#23 is closed** |
>
> **The job has also changed shape.** PR #55 already wrote the four-reason table and the host-bodyless / engine-renders distinction into the README — but filed them under the *Impersonation* section, which is the wrong home. So this plan is now **"relocate and complete"**, not "write": move that content to the "When access is denied" section this plan proposes, and add what is still genuinely missing — the override seam and its declaration order, the `rescue_from StandardError` shadowing trap, the HTML and JSON recipes, and the install-time warning that an existing controller suite goes red until it seeds grants. None of those exist anywhere today.
>
> Verify every claim below against the tree before acting on it, including this table.

---

## Product Contract

> **Product Contract preservation:** documentation issue, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded entirely in the filed finding (`issue #24`) and re-verified against `lib/current_scope/mutation_guard.rb`, `lib/current_scope/guard.rb`, `lib/generators/current_scope/install/install_generator.rb`, and `README.md` on 2026-07-15.

### Summary

Teach every reader what a CurrentScope denial actually *does* at the HTTP boundary, and how to shape it. The gem is fail-closed, so the denial is the first behavior every adopter meets — signed-out users, ungranted users, and (critically) every pre-existing controller test all hit it within the first ten minutes. Today that behavior is documented only in the source. We add one README section, one install-time callout, and one line of generator output. No engine behavior changes.

### Problem Frame

Three concrete, verified pains, all rooted in the same undocumented fact — **`include CurrentScope::Guard` silently installs `rescue_from CurrentScope::AccessDenied` (`mutation_guard.rb:24`) that renders `head :forbidden` (`mutation_guard.rb:49-53`): a correct 403 with a completely empty body**, the only signal being the `X-Current-Scope-Reason` header:

1. **Blank 403, no guidance (minor, ux — all six scenario apps).** Humans see a blank white page; API clients get no JSON error object. The README (`README.md:486-488`) documents the reason header but never says a denial renders an empty body, nor how to render something better.
2. **`rescue_from StandardError` shadowing (major, dx — 02_custom_actions).** Rails matches `rescue_from` handlers last-registered-first. A host catch-all error page registered *after* the `Guard` include (very common in `ApplicationController` or a base subclass) swallows `AccessDenied` (a `StandardError` subclass, `lib/current_scope.rb:18`) and turns *every* denial in that controller tree into a 500 — the reason header vanishes; ops and monitoring read internal-server-error.
3. **Install turns an existing suite red (major, dx — 01_baseline_blog).** After install, 14/14 scaffold controller tests fail with `<403: Forbidden>` and an empty body; no reason is visible in minitest output. The README's Testing section documents `grant_role!`/`with_current_user` but neither the install steps (`README.md:67-133`) nor the generator output (`install_generator.rb:14-30`) connect them to the guaranteed-red first run.

The override seam already exists and works — a host `rescue_from CurrentScope::AccessDenied` registered *after* the include wins and can render a friendly page (verified passing in scenario apps 01 and 06). It is simply documented nowhere.

### Requirements

- **R1.** The README gains a **"When access is denied"** section immediately after Installation, documenting the default: `include CurrentScope::Guard` auto-installs a `rescue_from` that returns, **for a host controller**, a **403 with an empty body** plus the `X-Current-Scope-Reason` header — and enumerating the **four denial** reason codes a 403 can carry (`:no_grant`, `:sod_veto`, `:impersonation_gate`, `:not_full_access`). The empty body is the *host* contract specifically: the engine's own console renders an explanation page for its front door, and that distinction has to be stated or a reader will expect one behaviour and meet the other. PR #55 already wrote this table and this distinction into the README, filed under *Impersonation* — R1 is to **move** it to the new section and complete it, not to author it fresh. It must also call out `:sod_bypassed` *separately*: that value rides the same header on an **allowed** (audited break-glass) **200**, not a denial (`resolver.rb:38`, `guard.rb:77`), so a reader never reads `X-Current-Scope-Reason: sod_bypassed` as a refusal.
- **R2.** The section documents the **supported override seam**: a host `rescue_from CurrentScope::AccessDenied, with: :...` registered **after** `include CurrentScope::Guard` wins (Rails resolves handlers last-registered-first), and a handler registered *before* the include silently never fires.
- **R3.** The section documents the **`rescue_from StandardError` shadowing trap** — a broad catch-all registered after the include converts denials to 500 and drops the reason header — with a concrete avoidance recipe: either register a `rescue_from CurrentScope::AccessDenied` handler **after** the catch-all so the later, denial-specific handler wins for that class, or narrow the catch-all so it never matches `AccessDenied`. (Do **not** re-raise `AccessDenied` from the catch-all — Rails does not re-dispatch a re-raised exception to a sibling `rescue_from`; see KTD-2.)
- **R4.** The section provides two copy-able recipes, **both reading `AccessDenied#reason`**: a branded HTML 403 page, and a JSON/API error body (for `ActionController::API` controllers with no view layer).
- **R5.** The **Installation** section gains a callout that after install, **existing controller tests will 403** until each signs in a subject and seeds a grant, linking the Testing section and `CurrentScope::TestHelpers` (`grant_role!` / `grant_scoped_role!` — the helpers a test includes). Seeding the baseline roles/first grant is `CurrentScope.seed_defaults!` / `CurrentScope.grant!` (module methods, from `db/seeds.rb`), **not** `TestHelpers` methods — keep the namespaces distinct so the doc doesn't emit `CurrentScope::TestHelpers.seed_defaults!` (which does not exist).
- **R6.** The generator's `show_next_steps` output gains a line pointing at the denial-rendering docs and warning that **existing controller tests need grants**, so a fresh installer reads it before running the suite. (Generator string only — no behavior change.)

---

## Key Technical Decisions

- **KTD-1 — Document the current default; do NOT change `current_scope_denied`.** The blank-`head :forbidden` default is intentional: it is view-layer-agnostic (works identically for `ActionController::Base` and `ActionController::API`), never assumes the host has a 403 template, and never leaks internal detail into a body. Shipping an opinionated error page under a `documentation` label would surprise upgraders and pre-empt the dedicated engine-403 work. This plan therefore *explains* the seam rather than replacing the default. If, while writing, the honest documentation makes the default look indefensible, that is a signal for issues #23/#39 — surface it, don't smuggle a code change in here (Stop condition (a)).
- **KTD-2 — Teach the `rescue_from` ordering model explicitly, because the footgun IS the ordering.** The shadowing bug is not a gem defect; it is standard Rails `rescue_from` last-registered-first resolution meeting a `StandardError` subclass. The only correct fix is documentation that makes the ordering rule visible and gives the host a deterministic recipe. The recommended default: register a `rescue_from CurrentScope::AccessDenied` handler **after** any broad `StandardError` catch-all — Rails resolves `rescue_from` last-registered-first, so the later, denial-specific handler wins for that class — or narrow the catch-all so it never matches `AccessDenied`. **Do not tell hosts to re-raise `AccessDenied` from the catch-all:** Rails resolves `rescue_from` once per exception, so a handler that re-raises escapes to the exception middleware (a 500 / debug page) — it is *not* re-dispatched to the sibling `AccessDenied` handler, so re-raising renders a 500, not the intended 403. One rule, stated once, covers all three scenario failures.
- **KTD-3 — Warn in BOTH the README install steps AND the generator output (belt and suspenders).** The generator output (`show_next_steps`) is what a fresh installer actually reads at install time; the README is what they search later when the suite is already red. R5 and R6 are deliberately redundant — the cost is two sentences, the payoff is catching the "guaranteed-red first run" at the moment it happens.
- **KTD-4 — One README section, not a new `docs/guides/` file.** There is no `docs/guides/` tree today (`docs/` holds ROADMAP/RESEARCH/READINESS + plans). The denial story is short, first-ten-minutes material that belongs inline in the README next to Installation, not in a separate guide a new user won't find. Ponytail: reuse the existing README structure; add a top-level `## When access is denied` between `## Installation` and `## Usage`.

---

## Implementation Units

### U1. README "When access is denied" section

- **Goal:** add a top-level `## When access is denied` section between `## Installation` and `## Usage` that documents the default rendering, the reason header + codes, the declaration-order override seam, the `StandardError` shadowing trap, and the HTML + JSON recipes.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** none.
- **Files:** `README.md`.
- **Approach:** new `## When access is denied` heading after line 132 (end of Installation), before `## Usage` (line 134). Structure, directional:
  1. **The default.** State plainly: `include CurrentScope::Guard` installs `rescue_from CurrentScope::AccessDenied` for you; an unauthorized request gets **HTTP 403 with an empty body** and an `X-Current-Scope-Reason` header. Show a `curl -i` example ending in `403 Forbidden` / `x-current-scope-reason: no_grant` / empty body. Enumerate the **three denial** reason codes a 403 can carry (`:no_grant`, `:sod_veto`, `:impersonation_gate`), and call out separately that `X-Current-Scope-Reason: sod_bypassed` rides an **allowed** 200 — an audited break-glass override (`guard.rb:77`), returned with `allowed=true` (`resolver.rb:38`) — so a reader never mistakes it for a denial. Mirror the existing header note (`README.md:486-488`), which deliberately omits `:sod_bypassed`, and cross-link it.
  2. **Overriding it.** A host `rescue_from CurrentScope::AccessDenied, with: :render_denied` in `ApplicationController` **after** `include CurrentScope::Guard` wins, because Rails resolves `rescue_from` handlers **last-registered-first**. Note the trap in the other direction: a handler registered *before* the include never fires. Show the branded-HTML recipe reading `exception.reason` to pick a message/status and rendering a real 403 template.
  3. **The `StandardError` shadowing trap** (call it out loudly — it is the major-severity finding). A broad `rescue_from StandardError` registered after the include swallows `AccessDenied` (it is a `StandardError`, `lib/current_scope.rb:18`) and turns every denial into a 500, losing the reason header. Give the deterministic recipe: register `rescue_from CurrentScope::AccessDenied, with: :render_denied` **after** the catch-all — Rails resolves `rescue_from` last-registered-first, so the later, denial-specific handler wins for that class and renders a 403 — or narrow the `rescue_from StandardError` so it never matches `AccessDenied` in the first place. Warn *against* the tempting-but-broken option: re-raising `AccessDenied` from the catch-all does **not** render a 403 — a `rescue_from` handler that re-raises escapes to the exception middleware (500 / debug page); Rails does not re-dispatch it to the sibling `AccessDenied` handler.
  4. **JSON / API variant.** For `ActionController::API` (no view layer), a `rescue_from CurrentScope::AccessDenied` that renders `{ error: ..., reason: exception.reason }, status: :forbidden`. Note this is the *only* denial rendering an API host gets unless it adds one — the default `head :forbidden` gives API clients no body.
- **Patterns to follow:** the prose voice and code-fence style of the existing Impersonation section (`README.md:374-502`), which already documents a seam + a footgun (`skip_before_action :current_scope_mutation_guard!`); mirror its "runs first / must opt out" framing for "registered last / wins". Keep recipes copy-able and self-contained.
- **Test scenarios:** Test expectation: none — documentation only. (The behavior each recipe documents is already covered by the scenario-app ProbesTests cited in the issue; this unit describes, it does not change, that behavior.)
- **Verification:** README renders; the section sits between Installation and Usage; every claim (empty body, header, reason codes, last-registered-first, shadowing→500) matches `mutation_guard.rb:22-53` and `lib/current_scope.rb:18` as read on 2026-07-15; both recipes are self-contained and read `#reason`.

---

### U2. Installation callout: existing controller tests will 403

- **Goal:** warn, inside the Installation section, that after install every pre-existing controller test 403s until it signs in a subject and seeds a grant — linking the Testing section and `CurrentScope::TestHelpers`.
- **Requirements:** R5.
- **Dependencies:** none (independent of U1, but reads best after it lands).
- **Files:** `README.md`.
- **Approach:** short callout after the "Bootstrap the first admin" block (around `README.md:127-132`), before `## Usage`. Directional content: "**Heads up — your existing controller tests will now 403.** The gate is fail-closed, so every request without a signed-in, granted subject returns 403 with an empty body (minitest shows `Expected response to be a <2XX: success>, but was a <403: Forbidden>` with no reason, because the reason lives in a header). Seed real grants in `setup` with `grant_role!` and sign the subject in — see [Testing your app](#testing-your-app)." Link to the existing anchor (README line ~504). Do not duplicate the Testing recipe; point at it.
- **Patterns to follow:** the existing inline-callout style already used in Installation (Assumption #1 block, `README.md:98-115`).
- **Test scenarios:** Test expectation: none — documentation only.
- **Verification:** callout appears in Installation; the intra-doc link resolves to the Testing section; the quoted minitest failure string matches the issue evidence (`<403: Forbidden>` empty body).

---

### U3. Generator `show_next_steps` — denial + test-grant line

- **Goal:** add one step to the install generator's next-steps output so a fresh installer is told, at install time, that denials render a blank 403 (customizable) and that existing controller tests need grants.
- **Requirements:** R6.
- **Dependencies:** none. (Redundant-by-design with U2 — KTD-3.)
- **Files:** `lib/generators/current_scope/install/install_generator.rb`.
- **Approach:** extend the `show_next_steps` heredoc (`install_generator.rb:14-30`) with a new numbered step after the "Manage roles at /current_scope" line, directional: `5. Denials render a 403 with an empty body by default (reason on the X-Current-Scope-Reason header). To brand them, or to keep your existing controller tests green (they will 403 until you seed grants), see "When access is denied" in the README.` Keep it to two lines; no logic, no new deps — this is a string edit to an existing `say` block. Match the imperative, numbered style already in the heredoc.
- **Patterns to follow:** the existing numbered-step format in the same heredoc (`install_generator.rb:17-27`).
- **Test scenarios:** Test expectation: none — no generator test exists in `test/` (verified 2026-07-15: no `*generator*` spec), and this is inert string output. If a generator test is later added, it should assert the next-steps output mentions "When access is denied".
- **Verification:** running `bin/rails generate current_scope:install` in a scratch app prints the new step; the heredoc still renders (no interpolation errors); wording points at the README section from U1.

---

## Scope Boundaries

**In scope:** one new README section (U1), one Installation callout (U2), one generator next-steps line (U3), and a `CHANGELOG.md` "Unreleased" documentation note. Faithful description of the *current* denial behavior only.

**Explicit non-goals — preserve deliberate design:**
- **No change to `current_scope_denied`** (`mutation_guard.rb:49-53`). The blank `head :forbidden` default stays; changing it is out of scope for a `documentation` issue and is the subject of #23/#39 (see Cross-issue coupling). This is the load-bearing boundary — KTD-1 and Stop condition (a).
- No new default 403 view/template, no default JSON error renderer, no config knob for denial rendering. We document the seam; we do not build an opinionated default.
- No change to the route-derived catalog, the fail-closed posture, or the auto-installed `rescue_from` itself.

**Deferred to Follow-Up Work (tangential):**
- If #23/#39 lands an improved default (e.g. a reason-carrying body, or a `config.denied_with` hook), this section must be revised to document the new default — note the coupling in that plan.
- A standalone `docs/guides/` adoption guide (companion to #26) could later absorb an expanded version of this section; not needed now (KTD-4).

---

## Open Questions

- **Reason-code list source of truth.** R1 enumerates the three **denial** reason codes a 403 can carry — `:no_grant`, `:sod_veto`, `:impersonation_gate` — plus `:sod_bypassed`, which is *not* a denial: it rides the same `X-Current-Scope-Reason` header on an **allowed** 200 (`resolver.rb:38` returns `[true, :sod_bypassed]`; `guard.rb:77` sets the header on that allow). Confirm this is the complete, current set before publishing — if the resolver adds reasons, the README enumeration should be kept in sync (or generated). Assumed complete as of 2026-07-15.
- **Recommended shadowing recipe.** Two valid framings for KTD-2's recipe: (a) "register `rescue_from CurrentScope::AccessDenied` explicitly, **after** your catch-all — Rails resolves handlers last-registered-first, so the later handler wins for that class"; (b) "narrow / remove the `rescue_from StandardError` catch-all so it never matches `AccessDenied`". Both work in Rails; (a) is the smaller, more idiomatic diff for hosts. Plan assumes (a) as the primary recipe with (b) as the alternative — maintainer to confirm preference. **Note:** an earlier draft listed "re-raise `AccessDenied` from your catch-all" as an option — it is wrong and has been removed. Rails resolves `rescue_from` once per exception; a handler that re-raises escapes to the exception middleware (500), it is *not* re-dispatched to the sibling `AccessDenied` handler, so it renders a 500 rather than the intended 403.

---

## Cross-issue coupling

- **#24 (this) ↔ #23 (engine-403) ↔ #39 (denial ergonomics) — the denial-behavior cluster.** This plan documents the *current* blank-403 behavior and the override seam **without changing any engine code**. #23/#39 are where the *behavior* of `current_scope_denied` (a real 403 body, a `config.denied_with` hook, or JSON-aware rendering) may change. Compose them in this order: land #24's docs now (they are correct against today's code and unblock adopters immediately); if #23/#39 later changes the default, revise the U1 section's "The default" subsection as part of *that* plan, keeping the override-seam and shadowing-trap subsections (which remain true regardless of the default). The Stop condition in the Goal Capsule is the guardrail that keeps #24 from silently absorbing #23/#39's code change.
- **#24 ↔ #26 (adoption guide).** The "existing tests go red" callout (U2) and the denial recipes (U1) are prime candidates for the broader adoption/onboarding guide #26. When #26 is planned, link to this README section rather than duplicating it.
