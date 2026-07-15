---
title: Security & Production Checklist Page (excluded=unprotected, 403/404 oracle, foot-guns, deploy checklist) - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/32
---

# Security & Production Checklist Page - Plan

## Goal Capsule

- **Objective:** give the deployer **one findable page** that names the places where CurrentScope's fail-closed promise can quietly become fail-open or leak information, plus the going-to-production checklist. Concretely: (1) `excluded_controllers` + `skip_before_action :current_scope_check!` leaves a controller protected by **nothing** from CurrentScope — a consequence the error, README, and initializer all state the mechanics of but never the *result*; (2) the README's own record-loading recipe produces a **403-vs-404 divergence** that lets an unauthorized caller probe which record ids exist; (3) the three documented foot-guns (nil-record SoD skip, `actor_method` unset, key-derivation mismatch) live in deep blockquotes far from where the mistake is made; (4) production concerns (audit `:strict`, first-admin on a fresh prod DB, the impersonation prod env-gate, clearing act-as on sign-in/out) have no single home. The change is **docs-plus-three-one-line-warning-strings** — no decision-code, resolver, Guard behavior, or catalog changes.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `docs/ROADMAP.md`, `resources/DESIGN.md`). The engine invariants are **immutable and untouched by this issue**: resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **PURITY** (no writes / no per-decision state), and the ambient `CurrentAttributes` context. The one non-doc file this plan edits is the **text of a `raise` message** in `guard.rb` (inert string, no control-flow change) and two comment blocks. This plan **documents** the 403/404 oracle and the excluded-means-unprotected consequence; it does **not** change how the Guard loads records or renders denials.
- **Stop conditions — surface rather than guess if:**
  - (a) making the checklist accurate would require *changing* engine behavior — e.g. reordering the record-load-before-decide contract (`guard.rb:48` loads the record before `guard.rb:53` decides) to close the 403/404 oracle, or auto-normalizing AccessDenied to 404. That contract is deliberate (the resolver needs the record to weigh scoped roles / SoD) and is documented, not coded around. The fix is a *mitigation recipe* the host opts into, never an engine default (Open Questions Q1);
  - (b) appending the "= ungated" sentence to the `ConfigurationError` message (`guard.rb:42-45`) would break a test asserting the exact string — verified 2026-07-15 that no test asserts on the message text (`test/integration/guard_test.rb:72-78` asserts only the error *class*), so this is safe; re-confirm before editing;
  - (c) the new page's cross-links to "When access is denied" (#24) or the canonical quickstart (#25) point at sections that don't exist yet — coordinate landing order (Cross-issue coupling), don't invent link targets.

---

## Product Contract

> **Product Contract preservation:** documentation issue, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded entirely in the filed finding (`issue #32`) and re-verified 2026-07-15 against `lib/current_scope/guard.rb:33-95` (the gate, the record-before-decide ordering at :48/:53, the nil-SoD nudge), `lib/current_scope/mutation_guard.rb:29-53` (`AccessDenied → head :forbidden`), `lib/current_scope/configuration.rb:51-55,157-179` (`excluded_controllers`, the prod impersonation env-gate), `lib/generators/current_scope/install/templates/initializer.rb:70-73` (excluded-controllers comment), and `README.md`'s foot-gun and loud-behaviour notes (key-derivation foot-gun, record-level recipe, nil-SoD note, config loud-behaviors, actor_method note, clear-act-as note).

### Summary

Every security caveat CurrentScope has is *technically* documented, but scattered across blockquotes and prose, and two of them never state the security **consequence** at all:

| Caveat | Where it lives today | What's missing |
|---|---|---|
| **excluded + skip = ungated** | `guard.rb:42-45` error, `README.md:368-372`, `initializer.rb:70-73` — all describe the *mechanics* (exclude → must skip) | none of the three states the **result**: after the skip the controller is protected by nothing from CurrentScope (BYO auth) |
| **403/404 record oracle** | nowhere — the recipe at `README.md:200-221` recommends the exact pattern that produces it | the side channel and a 404-normalization mitigation for sensitive resources |
| **nil-record SoD skip** | `README.md:264-272` blockquote | not linked from where the mistake is made (the record-level recipe) or from a security page |
| **`actor_method` unset** | `README.md:391-402` blockquote | no security-page home |
| **key-derivation mismatch** | `README.md`'s "Residual foot-gun — namespaced/custom-named controllers" note blockquote | no security-page home |
| **production concerns** (audit `:strict`, first-admin, prod impersonation env-gate, clear act-as) | scattered across README | no single going-to-production checklist |

Fail-closed is the product promise. The places where it quietly becomes fail-open (excluded+skip) or leaks information (403/404) deserve one page a deployer can read before shipping.

### Problem Frame

Two verified findings, both **docs-gap** (the mechanics are correct; the *consequence* is unstated), plus a consolidation need:

1. **excluded + skip leaves the controller completely unprotected — consequence never stated (major).** `config.excluded_controllers += [/\Aadmin\//]` then a GET raises the documented `ConfigurationError` (good, loud). Following its own advice — `skip_before_action :current_scope_check!` on `Admin::BaseController` — a signed-in user with **zero** CurrentScope grants then gets `GET /admin/reports → 200` and `POST /admin/reports/:id/approve → 302` (report actually approved). Only the host's own `require_admin!` stands between an ordinary user and admin actions. The mechanics are documented in three places (`guard.rb:42-45`, `README.md:368-372`, `initializer.rb:70-73`); the *consequence* — "this makes the actions ungated by CurrentScope; bring your own auth" — appears in **none** of them.
2. **403-vs-404 divergence is a record-existence oracle (minor).** With the README-recommended hook (`def current_scope_record = set_report if request.path_parameters[:id]`, using `Model.find`), a signed-out or zero-grant caller sees: existing id → **403** (`X-Current-Scope-Reason: no_grant` — the hook loads the record, then the gate denies), missing id → **404** (`ActiveRecord::RecordNotFound` raised *inside the hook*, which by documented design runs at `guard.rb:48` **before** `resolver.decide` at `guard.rb:53`). An anonymous/no-grant caller can enumerate which ids exist, and the Guard triggers real DB loads for anonymous requests. This is inherent to the record-before-decide contract (the resolver needs the record to weigh scoped roles and SoD) — it is a **trade-off to document with a mitigation recipe**, not a bug to code away.
3. **Foot-guns and production concerns have no findable home (consolidation).** The three foot-guns and the four production concerns are all individually documented but scattered; a deployer has no single checklist to run before shipping.

### Requirements

- **R1.** A new page `docs/SECURITY-CHECKLIST.md` ("Security & going to production") exists and is **linked from the README quickstart / top-of-README**, so a deployer can find it before shipping. It is organized as a scannable checklist, not prose.
- **R2.** The page states plainly, as its lead item, that **an excluded controller that skips the gate is protected by nothing from CurrentScope** — after `skip_before_action :current_scope_check!` the host must supply its own authorization (`require_admin!` or equivalent). It shows the exact reproduction shape (exclude → skip → zero-grant user reaches the action) and the safe alternatives (don't exclude; or exclude + skip **and** add host auth).
- **R3.** The `ConfigurationError` message (`guard.rb:42-45`) gains **one sentence** naming the consequence of the skip it recommends: skipping the gate leaves the controller ungated by CurrentScope — protect it with your own auth. Inert string change; no control-flow change; no test asserts the message text (verified).
- **R4.** The `excluded_controllers` comment in the **initializer template** (`initializer.rb:70-73`) and in **`configuration.rb`** (`:51-55`) gains the same one-line consequence note (excluded + skip = ungated by CurrentScope → BYO auth), so the warning is present at the point of configuration, not only on the page.
- **R5.** The page documents the **403-vs-404 record-existence oracle**: why it happens (record loaded before the decision, by design — `guard.rb:48` before `:53`), who it affects (unauthorized/anonymous callers can enumerate ids on member actions), and a **mitigation recipe** for sensitive resources — rescue `ActiveRecord::RecordNotFound` (or `AccessDenied`) to a uniform 404 so existing-but-forbidden and missing are indistinguishable. The recipe is presented as an **opt-in host choice for sensitive resources**, explicitly not an engine default (the divergence is acceptable for most apps).
- **R6.** The README's **"Record-level decisions"** recipe (`README.md:200-221`) gains a one-line cross-reference to (a) the nil-record SoD note already in the README and (b) the new 403/404 oracle mitigation on the security page — placed where the reader is writing the exact hook that produces both foot-guns.
- **R7.** The page collects the **three foot-guns** with links to their existing README treatments (not duplicating them): nil-record SoD skip (`README.md:264-272`), `actor_method` unset (`README.md:391-402`), key-derivation mismatch (`README.md`'s "Residual foot-gun — namespaced/custom-named controllers" note).
- **R8.** The page carries a **going-to-production checklist**: audit `= :strict` for audit-mandatory apps; bootstrapping the first admin on a fresh prod DB (rake task / `grant!`); the impersonation prod env-gate (`allow_mutations_while_impersonating` refused in production without `CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS`); clearing act-as on both sign-in and sign-out; and the `GatingTripwire` for catching ungated controllers in dev/test. Each item links its fuller README/section treatment.

---

## Key Technical Decisions

- **KTD-1 — The consequence warning goes in the shared seam (the `raise` message), not only on the page.** The excluded-means-unprotected consequence is missing from the *one place every deployer who makes this mistake actually reads*: the `ConfigurationError` that fires when they try to gate an excluded controller (`guard.rb:42-45`). Adding the sentence to the error is the root-cause fix — it reaches the developer at the moment of the mistake, whereas a docs page only reaches those who go looking. The initializer/config comments (R4) and the page (R2) are the belt-and-suspenders. One sentence in the shared error beats hoping the reader finds the page. **This is the lazy, root-cause placement** — the error message is the shared function all three callers (README, initializer, page) are really about.
- **KTD-2 — The 403/404 oracle is documented as a trade-off with an opt-in mitigation, NOT closed in the engine.** Closing it in the engine would mean either (a) deciding *before* loading the record (impossible — the resolver needs the record to weigh scoped roles and SoD, the whole `current_scope_record` contract) or (b) auto-rescuing every `RecordNotFound`/`AccessDenied` to a uniform 404 (a surprising, blast-radius-wide change to denial rendering that would break every host expecting a real 404 for a missing route and a 403 for a real denial). The divergence is **acceptable and even desirable** for most apps (a genuine 404 is correct UX for a missing record). The right fix is exactly what mature authorization libraries do: **document the enumeration trade-off and give sensitive-resource hosts a rescue-to-404 recipe they opt into.** No engine default changes. (Stop condition (a).)
- **KTD-3 — The page LINKS the existing foot-gun/production treatments; it does not duplicate them.** The nil-SoD note, `actor_method` note, key-derivation note, impersonation prod-gate, and audit tri-state are all already written correctly in the README. Duplicating them creates a fourth surface to drift (the same single-source discipline the quickstart plan #25 enforces). The security page is an **index + the two genuinely-new items** (excluded=unprotected consequence, 403/404 oracle + mitigation); everything else is a one-line pointer. This keeps the page short enough to actually be read as a pre-ship checklist.
- **KTD-4 — New page lives at `docs/SECURITY-CHECKLIST.md`, matching the existing `docs/` top-level uppercase convention.** Siblings are `docs/RESEARCH.md`, `docs/ROADMAP.md`, `docs/READINESS-AUDIT.md`. No `docs/guides/` tree is introduced (consistent with #24/#25 KTDs that keep docs flat). Linked from the README, not a new nav structure.

---

## Implementation Units

### U1. New `docs/SECURITY-CHECKLIST.md` page — the findable security & production home

- **Goal:** one scannable page a deployer reads before shipping, covering the two genuinely-new consequences (excluded=unprotected, 403/404 oracle) in full, and indexing the three foot-guns + four production concerns with links.
- **Requirements:** R1, R2, R5, R7, R8.
- **Dependencies:** none (but see U3 for the README link *to* it, and Cross-issue coupling for #24/#25 link targets).
- **Files:** `docs/SECURITY-CHECKLIST.md` (new).
- **Approach:** author the page as four checklist sections, in this order:
  1. **"Excluded + skipped = unprotected" (lead, R2).** State the consequence in the first sentence. Show the reproduction shape (exclude `/\Aadmin\//` → follow the error's advice `skip_before_action :current_scope_check!` → a zero-grant signed-in user reaches `GET /admin/reports` and `POST .../approve`). State the rule: **after the skip, CurrentScope enforces nothing on that controller — the host must supply its own authorization** (`require_admin!` etc.). Give the two safe shapes: (a) don't exclude it (let it be gated in the grid); (b) exclude + skip **and** add host auth. Cross-link the `GatingTripwire` (catches the *inverse* mistake — a controller that never included `Guard`).
  2. **"403 vs 404 leaks which records exist" (R5).** Explain the mechanism grounded in source: the `current_scope_record` hook loads the record (`guard.rb:48`) **before** the decision (`guard.rb:53`), by design (the resolver needs the record). So existing-but-forbidden → 403 (`no_grant`), missing → 404 (`RecordNotFound` from inside the hook). An unauthorized/anonymous caller can enumerate ids, and anonymous requests trigger real DB loads. State the trade-off honestly (a real 404 is correct UX for most apps). Give the **opt-in mitigation** for sensitive resources — directional:
     ```ruby
     # For a sensitive resource, make "forbidden" and "missing" indistinguishable
     # to an unauthorized caller. In the controller (or a concern):
     rescue_from ActiveRecord::RecordNotFound, with: :render_404
     # and normalize CurrentScope::AccessDenied to 404 too, so both look identical:
     rescue_from CurrentScope::AccessDenied, with: :render_404   # overrides the engine's :forbidden
     ```
     Note the cost: you lose the machine-readable 403 reason header for that resource, and legitimate users see 404 instead of 403 on a real denial — that's the point (indistinguishability), and it's why it's opt-in per sensitive resource, not global.
  3. **"Foot-guns" (R7).** Three bullets, each one line + a link to the existing README treatment: nil-record SoD skip → `#separation-of-duties-opt-in`; `actor_method` unset → `#impersonation-act-as`; short-form key-derivation mismatch on namespaced controllers → the `allowed_to?` note.
  4. **"Going to production" checklist (R8).** Ticklist: set `config.audit = :strict` if audit is mandatory (missing events table rolls the mutation back rather than committing unaudited); bootstrap the first admin on the fresh prod DB (the management UI needs a full-access subject to enter — `bin/rails current_scope:grant` / `CurrentScope.grant!`); if you enable `allow_mutations_while_impersonating`, production refuses it without `CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS` (fail-loud at boot); clear act-as on **both** sign-in and sign-out; add `GatingTripwire` in dev/test to catch ungated controllers. Each links its README section.
- **Patterns to follow:** the README's voice and code-fence style; the honest-framing register used by the "Break-glass override" and "Impersonation" sections (state the security consequence plainly, then the recipe). Keep every already-documented item to a one-line pointer (KTD-3) so the page stays checklist-length.
- **Test scenarios:** Test expectation: none — documentation only. Every claim re-verified against source as cited: record-before-decide (`guard.rb:48` before `:53`), `AccessDenied → head :forbidden` (`mutation_guard.rb:52`), excluded-controller raise (`guard.rb:41-46`), prod impersonation env-gate (`configuration.rb:161-173`), audit tri-state (`configuration.rb:98-111`).
- **Verification:** the page exists, reads as a checklist, leads with the excluded=unprotected consequence, contains the 403/404 mechanism + opt-in mitigation recipe, indexes the three foot-guns and four production items with working intra-repo links; no already-documented item is duplicated beyond a one-line pointer.

---

### U2. State the consequence at the source — `ConfigurationError` message + two config comments

- **Goal:** the deployer who trips the excluded-controller error, or reads the `excluded_controllers` config comment, sees the *consequence* of the skip the error recommends — not just the mechanic.
- **Requirements:** R3, R4.
- **Dependencies:** none (independent of U1; the message can name the page once U1 lands, or stay self-contained).
- **Files:** `lib/current_scope/guard.rb` (the `raise` message, `:42-45`), `lib/generators/current_scope/install/templates/initializer.rb` (`:70-73`), `lib/current_scope/configuration.rb` (`:51-55`).
- **Approach:** append one sentence to each, all saying the same thing directionally: *"Skipping the gate leaves this controller ungated by CurrentScope — protect it with your own authorization (e.g. `require_admin!`)."* In `guard.rb` this is one more line in the existing multi-line string (after "...skip the gate here with skip_before_action :current_scope_check!."). In `initializer.rb` and `configuration.rb`, one more comment line after the existing "must also skip the gate ... Guard raises otherwise." No control-flow, no new config, no behavior change — the `raise` still raises the same class with the same trigger; only the human-readable text grows.
- **Execution note:** verified 2026-07-15 that **no test asserts on the message text** — `test/integration/guard_test.rb:72-78` asserts only `assert_raises(CurrentScope::ConfigurationError)` (the class), and a repo-wide search found the string only in `guard.rb` itself. Appending a sentence is safe. Re-confirm with a search before editing (Stop condition (b)).
- **Patterns to follow:** the existing multi-line `raise ConfigurationError, "..." \` string style in `guard.rb`; the existing comment-block voice in `configuration.rb`/`initializer.rb`.
- **Test scenarios:** Test expectation: none — inert string/comment change, no behavior to assert. (If a message-text assertion is ever added, it should match on a stable substring like "ungated by CurrentScope", not the whole string.)
- **Verification:** the three strings each name the consequence (ungated → BYO auth); the full test suite is unchanged and green (proving no message-text coupling); RuboCop clean.

---

### U3. Wire the page in — README link + "Record-level decisions" cross-reference

- **Goal:** make the new page findable from the README, and put the two record-hook foot-guns (nil-SoD skip, 403/404 oracle) in front of the reader at the exact spot they write the hook that causes them.
- **Requirements:** R1 (the link half), R6.
- **Dependencies:** U1 (the link target must exist).
- **Files:** `README.md`.
- **Approach:** (a) add a link to `docs/SECURITY-CHECKLIST.md` near the top of the README (a "Security & production" bullet in the intro list, or alongside the Design-notes links at the bottom — maintainer's call, see Open Questions) so a deployer discovers it before shipping. (b) In the **"Record-level decisions"** section (`README.md:200-221`), after the recipe code fence, add one line: the same hook that loads the record for scoped-role/SoD decisions has two foot-guns to know — returning **nil** on an SoD member action silently skips the veto (link the existing `#separation-of-duties-opt-in` note), and loading with `Model.find` means an unauthorized caller gets 403 for an existing id vs 404 for a missing one, a record-existence oracle (link the new security page's mitigation). No behavior change.
- **Patterns to follow:** the existing inline-blockquote-and-cross-link style already used in the README (e.g. the key-derivation foot-gun blockquote at `:154-163`); keep it to one or two lines with links, not a re-explanation (KTD-3).
- **Test scenarios:** Test expectation: none — documentation only.
- **Verification:** the README links the security page from a findable spot; the "Record-level decisions" recipe carries a one-line pointer to both the nil-SoD note and the 403/404 mitigation; links resolve.

---

## Scope Boundaries

**In scope:** the new `docs/SECURITY-CHECKLIST.md` page (U1); the one-sentence consequence appended to the `ConfigurationError` message and the two `excluded_controllers` comments (U2); the README link + "Record-level decisions" cross-reference (U3); a `CHANGELOG.md` "Unreleased" documentation note. Faithful description of *current* engine behavior only.

**Explicit non-goals — preserve deliberate design:**
- **No engine behavior changes.** The record-before-decide contract (`guard.rb:48` before `:53`) stays — it is required for scoped-role/SoD decisions and is deliberate; the 403/404 divergence is documented + given an opt-in host mitigation, never closed in the engine (KTD-2). `AccessDenied → head :forbidden` (`mutation_guard.rb:52`) is unchanged. The route-derived catalog, `excluded_controllers` semantics, and the fail-closed posture are untouched.
- **No new default 404-normalization**, no auto-rescue of `RecordNotFound`/`AccessDenied` — the mitigation is a recipe the host opts into per sensitive resource.
- **No duplication** of the already-correct foot-gun/production prose — the page links, it does not restate (KTD-3).
- The `ConfigurationError` still raises with the same class and same trigger; only its text grows (U2).

**Deferred to Follow-Up Work (tangential):**
- A `docs/`-hosted broader adoption guide (#26) could later absorb or link this checklist; when it lands it should link this page, not fork it.
- Mirroring the security checklist onto the `gh-pages` docs site (as #25 does for the quickstart) — nice-to-have, out of scope; the near-term win is the README-linked page.
- A `current_scope:doctor`-style boot-time check that warns when an excluded controller has skipped the gate without host auth is a possible future ergonomic aid (the engine can't detect host auth, so it would be heuristic) — not this issue.

---

## Open Questions

- **Where to link the page from the README (U3a).** A bullet in the intro capabilities list (highest visibility, read by everyone) vs. alongside the Design-notes links at the bottom (lower friction, less prominent). A pre-ship checklist wants visibility, so the intro/near-quickstart placement is the plan's default; the maintainer may prefer the Design-notes cluster to keep the intro tight. Either satisfies R1 as long as a deployer can find it.
- **How aggressive to make the 403/404 mitigation framing (U1 §2).** The plan documents rescue-to-404 as an opt-in for *sensitive* resources and is honest that most apps should keep the real 404. Confirm the maintainer wants it framed as "advanced / only if you have an enumeration threat model" rather than a blanket recommendation — over-recommending it would degrade UX (real 404s become 403-shaped) for apps that don't need it.

---

## Cross-issue coupling

- **#32 (this) ↔ #24 (denial-behavior docs).** The security page's 403/404 section and the going-to-production checklist both reference **what a denial renders** (blank 403 + `X-Current-Scope-Reason`), which #24 owns as the "When access is denied" README section. Plan assumes the page **cross-links** #24's section rather than re-explaining denial rendering. Confirm #24 lands first (or concurrently) so the link target exists (Stop condition (c)). The 403/404 *oracle* itself is this issue's; the *rendering* of the 403 is #24's — compose, don't duplicate.
- **#32 ↔ #25 (canonical quickstart).** #25 makes the README quickstart the single onboarding source and adds the `skip_before_action` step with a lockout warning. This issue's excluded=unprotected item and the going-to-production first-admin bootstrap both touch the same quickstart neighborhood — the security page should **link** #25's canonical quickstart for the bootstrap step rather than restating it, and the README link (U3a) is naturally placed next to the quickstart #25 establishes. Land after or with #25 so the quickstart anchor exists.
- **#32 ↔ #23 (engine-403-no-reason) / #39 (denial-ergonomics).** Part of the denial cluster: #23 routes the engine UI's own 403 through the `AccessDenied`/reason machinery, #39 covers denial ergonomics. The security page's 403/404 mitigation recipe (normalizing `AccessDenied` to 404) should stay consistent with however #23/#39 settle the reason-header contract — the recipe deliberately *drops* the reason header for the normalized resource, which is the intended trade-off; note that so it doesn't read as contradicting the #23/#39 "always surface a reason" direction.
