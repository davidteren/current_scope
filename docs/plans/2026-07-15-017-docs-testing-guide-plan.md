---
title: Testing guide — denial assertions, actor: keyword, and an RSpec variant - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/35
---

# Testing guide — denial assertions, `actor:` keyword, and an RSpec variant - Plan

## Goal Capsule

- **Objective:** extend the README "Testing your app" section so it teaches the tests that actually matter for an authorization gem — proving a **denial** (403 + `X-Current-Scope-Reason`), impersonation setup via the existing `actor:` keyword, an **RSpec** variant of the helper flow, and a note that system tests exercising mutations under impersonation must wire the mutation-guard skips. Documentation only; no engine behavior changes.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `docs/ROADMAP.md`). Every code fact the guide states must match source as it stands today. The engine invariants are **immutable and not touched here**: resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **purity** (no writes, no per-decision state), and ambient `CurrentAttributes` context. This is a docs change — it must *describe* those invariants accurately, never alter them.
- **Ground truth already in source (verified 2026-07-15):**
  - Denials render `head :forbidden` and set `response.headers["X-Current-Scope-Reason"] = reason.to_s` — `lib/current_scope/mutation_guard.rb:49-53` (`current_scope_denied`, wired via `rescue_from CurrentScope::AccessDenied`).
  - Reason values a host will assert on: `:no_grant`, `:sod_veto`, `:impersonation_gate` (README §Impersonation, and `MutationGuard#current_scope_mutation_guard!` raising `:impersonation_gate`).
  - The `actor:` keyword already exists: `with_current_user(user, actor: nil)` — `lib/current_scope/test_helpers.rb:20`; today it is only shown in that file's header comment, not in README.
  - `grant_role!` / `grant_scoped_role!` persist real assignment rows for request/system specs — `lib/current_scope/test_helpers.rb:43-51`.
  - The mutation-guard skip endpoints (`skip_before_action :current_scope_mutation_guard!`) are already documented for controllers — README:476-484 — but not from the *test-writing* angle.
- **Stop conditions (surface rather than guess):** stop and ask the maintainer if (a) writing the RSpec example would require the gem to add an RSpec dependency or shared-context file (it must not — `TestHelpers` is a plain module a host `include`s), (b) any drafted assertion would only pass if engine behavior changed (that means the doc is wrong or the behavior is — do not "fix" the doc to paper over it), or (c) the reason string for a plain no-grant denial in a request spec is not literally `"no_grant"` when checked against a running dummy app.

---

## Product Contract

> New docs work, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Source: automated shakedown finding #17, re-verified against gem source.

### Summary

The current "Testing your app" section (`README.md:504-545`) shows only allows: a component test with `with_current_user`, and a request test that seeds grants and asserts `:success`. For an authorization gem that is the least interesting half — the tests that prove the gate *works* are the ones asserting it **refuses**. This plan adds four missing pieces to that section: a denial assertion (`assert_response :forbidden` + the `X-Current-Scope-Reason` header), the `actor:` impersonation form (promoted out of the `test_helpers.rb` comment), an RSpec variant of the same include-and-grant flow, and a short system-test note that mutations exercised under impersonation need the mutation-guard skips wired or they will `403` for reasons unrelated to the test's intent.

### Problem Frame

Authorization testing is mostly negative-space testing: you assert the door is *locked* far more often than you assert it opens. A guide that only demonstrates the happy path quietly trains adopters to write tests that would still pass if the gate were removed entirely. Worse, the one impersonation affordance a host needs for act-as tests (`actor:`) is invisible unless they read the gem's source, and RSpec shops — a large share of Rails teams — get a Minitest-only example they must mentally port, with the request-spec `type: :request` and header-access differences left as an exercise. The result is under-tested denials in host apps, which is exactly the failure mode an authorization gem exists to prevent.

### Requirements

- **R1.** The guide shows a **denial** request test: an ungranted subject hits a gated action and the test asserts `assert_response :forbidden` **and** the `X-Current-Scope-Reason` header equals the machine-readable reason (`"no_grant"` for a plain missing grant).
- **R2.** The guide documents `with_current_user(user, actor: admin)` — the act-as form — with one sentence on when it applies (in-process checks of impersonation-aware affordances), mirroring the existing `test_helpers.rb` comment so the two never drift.
- **R3.** The guide includes an **RSpec** variant showing `include CurrentScope::TestHelpers` in a `type: :request` spec, seeding a grant and asserting both an allow and a denial with RSpec matchers (`have_http_status(:forbidden)`, `response.headers[...]`). It must not imply the gem ships any RSpec support beyond the plain includable module.
- **R4.** The guide adds a **system-test note**: a system/integration test that drives a *mutation* (non-GET) while impersonating hits the read-only mutation guard first, so either the test asserts that 403 deliberately, or the exercised controller must `skip_before_action :current_scope_mutation_guard!` (cross-referencing the existing controller guidance), so the denial under test is the *permission* denial the author intended.
- **R5.** Every code fact in the new prose is accurate to source at `docs/plans/…` write time — reason strings, method signatures, header name, and the persist-vs-in-process distinction between `grant_role!` and `with_current_user`.
- **R6.** No engine code changes; the section stays additive and self-contained. Existing testing prose (component + happy-path request examples) is preserved, not rewritten.

---

## Key Technical Decisions

- **KTD-1 — Docs-only; zero engine change.** Everything the guide needs already exists in source: the `actor:` keyword, the `grant_*` helpers, and the 403+header denial path. The honest fix is to *document* them, not to add a test DSL. No `assert_denied` sugar, no RSpec shared context, no matcher gem. (Ponytail: rung 2 — reuse what's already here. If host request-spec ergonomics later prove painful, a `with_sod_bypass`/denial helper is a separate, deferred decision — see Scope Boundaries.)
- **KTD-2 — Denial example uses `:no_grant`, the everyday reason.** A brand-new subject with no grant is the simplest, most common denial and yields `reason: :no_grant` → header `"no_grant"`. The example asserts that exact string. `:sod_veto` and `:impersonation_gate` are named in prose (they are already documented in their own sections) but the runnable example centers on `:no_grant` to stay minimal and not drag SoD/impersonation setup into a first denial test.
- **KTD-3 — RSpec variant is a mirror, not a port of behavior.** The RSpec block does the *same three things* as the Minitest one — `include CurrentScope::TestHelpers`, `grant_role!`, assert allow + assert forbidden — differing only in framework syntax (`type: :request`, `have_http_status`, `response.headers`). This keeps the two examples verifiably equivalent and signals that `TestHelpers` is framework-agnostic (a plain module), which is the actual point.
- **KTD-4 — System-test note cross-references, does not duplicate, the controller skip guidance.** The mutation-guard skip endpoints are already fully explained at `README.md:472-484`. The new note frames the *testing* consequence and links back, rather than restating the mechanism — one source of truth for "which controllers skip the guard."
- **KTD-5 — Verify the reason string against the running dummy app, not just by reading source.** `current_scope_denied` writes `reason.to_s`; a symbol `:no_grant` stringifies to `"no_grant"`. Cheap to confirm with one integration assertion in the dummy suite during authoring so the published example is copy-paste-correct (see Verification). This is the one place a "looks obvious" doc claim is worth a runtime check.

---

## Implementation Units

### U1. Denial assertion + `actor:` keyword in the README testing section

- **Goal:** add a runnable denial request test and document the act-as `actor:` form, inside the existing "Testing your app" section.
- **Requirements:** R1, R2, R5, R6.
- **Dependencies:** none.
- **Files:** `README.md` (the "Testing your app" section, currently lines ~504-545).
- **Approach:** After the existing happy-path `ReportsAccessTest`, add a sibling test in the same class (or an adjacent `test` block) where a subject with **no** grant `GET`s (or better, `POST`s to) a gated action and the test asserts:
  ```ruby
  # directional
  get admin_reports_path            # gated, subject holds no grant
  assert_response :forbidden
  assert_equal "no_grant", response.headers["X-Current-Scope-Reason"]
  ```
  One sentence of prose: denials render `head :forbidden` and carry the machine-readable reason on `X-Current-Scope-Reason` (`no_grant`, `sod_veto`, `impersonation_gate`), so tests can assert *why* the gate refused, not just that it did — link to the reason list already in the Impersonation section rather than re-enumerating. Separately, add a short paragraph + snippet for the act-as form, lifted from `test_helpers.rb:6-14`:
  ```ruby
  # directional
  with_current_user(users(:bob), actor: users(:admin)) do   # act-as: bob impersonated by admin
    assert impersonating?
  end
  ```
  Note it is for in-process checks of impersonation-aware affordances (banners, disabled destructive controls), and that a *real* impersonated mutation goes through the request path and the mutation guard (forward-reference U3's note).
- **Patterns to follow:** the existing section's two-example rhythm (component test, then request test) and its "in-process vs persisted grant" framing; the reason-list phrasing already at `README.md:486-488`.
- **Test scenarios:** none — documentation prose. The *example's* correctness is verified at runtime in U2's dummy assertion (KTD-5) so the published `"no_grant"` string is proven, not assumed.
- **Verification:** the section now shows a denial test asserting both status and header, and the `actor:` keyword appears in README (no longer source-comment-only); reason string and method signatures match `mutation_guard.rb` / `test_helpers.rb`.

### U2. RSpec request-spec variant

- **Goal:** add an RSpec `type: :request` example that mirrors the Minitest allow+deny flow, proving `TestHelpers` is framework-agnostic.
- **Requirements:** R3, R5, R6.
- **Dependencies:** U1 (shares the denial pattern and reason string it establishes).
- **Files:** `README.md` (same section, immediately after the Minitest examples).
- **Approach:** add a fenced `ruby` block, clearly labelled "RSpec", showing:
  ```ruby
  # directional
  RSpec.describe "Reports access", type: :request do
    include CurrentScope::TestHelpers

    it "lets a granted reviewer in but forbids an ungranted user" do
      grant_role!(reviewer, role: roles(:member))
      sign_in reviewer
      get reports_path
      expect(response).to have_http_status(:success)

      sign_in stranger                       # holds no grant
      post reports_path, params: { report: { … } }
      expect(response).to have_http_status(:forbidden)
      expect(response.headers["X-Current-Scope-Reason"]).to eq("no_grant")
    end
  end
  ```
  One line of prose: `CurrentScope::TestHelpers` is a plain module — `include` it in any Minitest or RSpec context; the gem ships no RSpec-specific support and needs none. Keep fixtures/`sign_in` as host-owned (`reviewer`, `stranger`, `roles(:member)` are illustrative), matching how the Minitest example already defers auth to the host.
- **Execution note (authoring check, KTD-5):** before publishing, confirm the denial reason string end-to-end. Add one throwaway/kept assertion in the engine's dummy integration suite (`test/dummy` + `test/integration/…`) that an ungranted request to a gated action returns `403` with `X-Current-Scope-Reason == "no_grant"`. If an equivalent assertion already exists in the suite, cite it instead of adding one. This proves both the Minitest (U1) and RSpec (U2) header claims with a single runtime fact.
- **Patterns to follow:** the existing Minitest request example's structure (include → grant → sign_in → assert); RSpec request-spec conventions (`type: :request`, `have_http_status`).
- **Test scenarios:** none for the doc prose itself. The backing runtime fact is the dummy-suite assertion in the Execution note: ungranted `POST` to a gated action → `403`, header `"no_grant"` (input: no RoleAssignment for the subject → expected: forbidden + reason header).
- **Verification:** an RSpec example is present, syntactically valid, and asserts both allow and forbidden with the correct header; the dummy assertion backing the `"no_grant"` string is green (or an existing one is cited).

### U3. System-test note: mutations under impersonation need the mutation-guard skips

- **Goal:** warn authors that a system/integration test driving a mutation while impersonating hits the read-only guard first, and tell them how to get the denial they actually intend.
- **Requirements:** R4, R5, R6.
- **Dependencies:** U1 (references the denial/reason vocabulary), U2.
- **Files:** `README.md` (same section, as a closing note; may use a `>` callout).
- **Approach:** add a short note: when a system test drives a non-GET action **while an act-as session is active**, the `current_scope_mutation_guard!` before_action denies it first with `reason: :impersonation_gate` — *before* any permission check. So a test meaning to prove a *permission* denial (or a permitted mutation) under impersonation must either (a) assert the `impersonation_gate` 403 deliberately, or (b) exercise a controller that opts out with `skip_before_action :current_scope_mutation_guard!` (the same sign-in/out and stop-impersonation endpoints already documented above — cross-reference `README.md`'s impersonation read-only subsection, do not restate the mechanism). Mention `config.allow_mutations_while_impersonating = true` as the global alternative for suites that need impersonated writes throughout, with a pointer to its production env-gate caveat (already documented) rather than re-explaining it.
- **Patterns to follow:** the existing impersonation read-only subsection (`README.md:450-484`) — this note is the *test-author's* corollary to it and should link, not duplicate.
- **Test scenarios:** none — documentation prose (the `:impersonation_gate` behavior it describes is already covered by the engine's own mutation-guard tests; no new assertion needed).
- **Verification:** the note is present, correctly names `:impersonation_gate` as the first-hit reason, and points to the existing skip-endpoint guidance rather than repeating it; an author reading only this section knows why an impersonated mutation test 403s and the two ways to fix it.

---

## Scope Boundaries

**In scope:** additive edits to the single README "Testing your app" section — a denial request test with header assertion, the `actor:` act-as keyword, an RSpec `type: :request` variant, and a system-test note about the mutation guard; plus one runtime assertion (new or cited) in the dummy suite to prove the `"no_grant"` reason string.

**In scope, but only if trivial:** confirming the reason string via an existing dummy integration test. If none exists, add exactly one; do not build a testing-doc example harness.

**Deferred to Follow-Up Work:**
- A dedicated denial/assertion test helper (e.g. `assert_current_scope_denied(reason:)` or a `with_sod_bypass` block) if host ergonomics later justify sugar over the raw `assert_response :forbidden` + header check. Not now — YAGNI; the raw assertions are three lines and framework-portable.
- Extending the install generator's `show_next_steps` (`lib/generators/current_scope/install/install_generator.rb`) with a "5. Test behind the gate" pointer. Tempting but out of this issue's scope; note as an Open Question, do not bundle silently.
- A standalone `docs/TESTING.md` guide. The content fits the README section; splitting it out is a structure decision for the maintainer, not this issue.

**Explicit non-goals / preserved design choices:** no engine code changes; no new dependency (RSpec stays a host concern); the route-derived catalog, opt-in SoD, and read-only-while-impersonating defaults are described, never altered. The existing component and happy-path examples stay.

---

## Open Questions

- **Generator next-step pointer?** Should `InstallGenerator#show_next_steps` gain a line pointing new installs at the testing section (`include CurrentScope::TestHelpers`)? It is a one-line, high-visibility nudge but slightly outside "testing guide." Default: leave it out of this issue; file a tiny follow-up if wanted.
- **Denial example verb — GET vs POST?** A `GET` to a gated collection action the subject can't reach is the simplest denial; a `POST` better models "prove the write is refused." U1/U2 lean `POST` for the mutation case but a `GET` denial is equally valid — maintainer's call on which reads clearest against the dummy app's routes.
- **Reason string surface:** confirm no host would reasonably assert on `:sod_veto`/`:impersonation_gate` in the *primary* example instead of `:no_grant`. Assumed no — those have their own sections; the testing section only needs to teach the *pattern*, with `:no_grant` as the representative case.

---

## Cross-issue coupling

This issue sits in the **denial-ergonomics cluster** the shakedown surfaced. If sibling issues are being planned in the same pass, the testing guide should compose with, and reuse the vocabulary of, whichever lands the denial-surface work:

- **Denial behavior / engine-403 (the `#23`/`#24`-style cluster):** if the reason vocabulary or the 403 rendering changes there (e.g. a JSON body, a new reason symbol), U1/U2's asserted header string must track it. The testing guide should be written *after* or *in sync with* any such change so the published example matches shipped behavior — otherwise the guide teaches an assertion that will fail. If that work is in flight, note the dependency and pin the example to the reason strings that ship.
- **Denial-ergonomics (`#39`-style):** if a denial/assertion test helper is introduced there, this guide's "raw assertions" become the *fallback* and the helper becomes the headline example — the deferred helper in Scope Boundaries is exactly that sibling's territory. Keep U1's raw-assertion example even then (it documents what the helper wraps).

Compose rule: this plan owns the *documentation* seam; a denial-surface issue owns the *behavior* seam. Land behavior first (or together), then let this guide assert against it — never the reverse.
