---
title: Error-message polish — double org-grant + excluded-controller diagnostics - Plan
type: feat
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/44
---

# Error-message polish — double org-grant + excluded-controller diagnostics - Plan

## Goal Capsule

- **Objective:** replace two *correct-but-cryptic* error messages with self-explaining ones. (a) A second org-wide grant for the same subject currently raises the bare Rails default `Subject has already been taken`; make it name the one-org-role-per-subject rule and point at the upsert (`CurrentScope.grant!`) or scoped roles. (b) The Guard's excluded-controller `ConfigurationError` hedges "excluded_controllers or not routed" and never says *which* regex matched; make it identify the matching pattern and distinguish the excluded case from the truly-unrouted case. Both are diagnostics-only: no decision, no grant, no gate behavior changes.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). The resolver decision order (SoD veto → full_access → org role → scoped role → deny), the **fail-closed** posture, the **one-org-role-per-subject** invariant, resolver **purity** (no writes / no per-decision state), and the ambient `CurrentAttributes` context are all **immutable**. This change touches only two message strings and the code that composes them; it must not move a single allow/deny outcome. The excluded-controller path **stays a loud raise** — enriching the message must never soften it into a deny or an allow.
- **Stop conditions:** stop and surface rather than guess if (a) any proposed change would alter whether an action is allowed, denied, or raised — this is a message-only change; (b) distinguishing "excluded" from "not routed" would require the resolver or catalog to hold new per-decision state or perform a write; (c) the new validation message would require dropping or weakening the `subject_id` uniqueness validation or its backing unique index (`index_current_scope_one_role_per_subject`); or (d) a house convention makes the tokens existing tests/docs assert on (`excluded_controllers`, `skip_before_action :current_scope_check!`, the `controller#action` key) unsafe to preserve verbatim.

---

## Product Contract

> **Product Contract preservation:** DX/polish enhancement, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded entirely in issue #44's two verified findings and the cited gem source.

### Summary

Two authorization outcomes are already correct; only their explanations send the reader to the gem source instead of the fix.

1. **Double org-grant.** `CurrentScope::RoleAssignment` enforces one org-wide role per subject via a `subject_id` uniqueness validation (`app/models/current_scope/role_assignment.rb:9`) backed by a unique index. A second grant — whether through the `grant_role!` test helper's bare `create!` (`lib/current_scope/test_helpers.rb:43-45`), a direct `RoleAssignment.create!`, or `grant!`'s `update!` — surfaces Rails' default `Subject has already been taken`. That message names neither the rule nor the two right answers (`CurrentScope.grant!` to *replace* the org role, or a **scoped role** for additive per-record access). Note the divergence the issue flags: `CurrentScope.grant!` (`lib/current_scope.rb:142-146`) *upserts* silently, while `grant_role!` *raises* — a fixture-seeded suite hits the raise on the first per-test override.

2. **Excluded-controller `ConfigurationError`.** When a gated action's `controller#action` key isn't in the route-derived catalog, the Guard raises (`lib/current_scope/guard.rb:41-46`) — correct: an excluded controller can never be granted, so gating it is a misconfiguration, not a deny (it raises even for a full-access Owner). But the static message hedges "(excluded_controllers or not routed)" and, with five default exclusion regexes plus any host additions (`lib/current_scope/configuration.rb:140-143`), never says which one matched. The information to resolve both nits is already in hand at the raise site: `config.excluded_controllers` (to find the matching regex) and the catalog (to tell "excluded" from "action/controller not routed").

### Problem Frame

`current_scope` is deliberately loud on misconfiguration and precise on denials — that is a selling point the README advertises ("Two loud-by-design behaviors"). These two messages are the exception: they're loud but not *precise*, so a developer who hits them has to open the gem to learn what the engine already knows. Naming the rule and the matching pattern turns each into a one-line, self-service fix. Neither is a correctness bug — both denials/raises are right — so the entire change lives in message composition, with the security-relevant guarantee being that **no outcome moves**.

### Requirements

- **R1.** A second org-wide `RoleAssignment` for a subject that already holds one fails with a message that (a) names the one-org-role-per-subject rule, (b) points to `CurrentScope.grant!` to *replace* the existing org role, and (c) points to **scoped roles** for additive per-record access — instead of the bare `Subject has already been taken`.
- **R2.** The improved message applies at the **model validation seam**, so every caller inherits it: the `grant_role!` helper, a direct `RoleAssignment.create!`, and `grant!`'s `update!` path alike. No per-caller patching.
- **R3.** The one-org-role-per-subject invariant is **unchanged**: the `subject_id`/`subject_type` uniqueness validation and its backing unique index both remain; only the human-readable message changes.
- **R4.** The Guard's excluded-controller `ConfigurationError` identifies the **matching `excluded_controllers` regex** when the controller path is excluded.
- **R5.** The Guard distinguishes the two cases it currently hedges between: **excluded** (controller path matches an exclusion regex) vs **not routed** (no exclusion matched — the controller or the specific action simply isn't in the route-derived catalog), and words the remedy per case.
- **R6.** The excluded-controller path **still raises `CurrentScope::ConfigurationError`** (fail-closed, unchanged for a full-access subject too), and preserves the tokens downstream consumers rely on: the `"controller#action"` key, the string `excluded_controllers` (excluded case), and `skip_before_action :current_scope_check!`.
- **R7.** No resolver change, no catalog data-model change, no new config: purity and the route-derived catalog are preserved (KTD-3).

---

## Key Technical Decisions

- **KTD-1 — Fix the double-grant message at the model, not at each caller (the shared seam).** The cryptic string originates from the `validates … uniqueness` on `RoleAssignment` (`role_assignment.rb:9`); `grant_role!`, direct `create!`, and `grant!`'s `update!` all route their write through that validation. A custom `message:` on the single validation is the root-cause, smallest-diff fix and automatically covers every present and future caller — one guard in the shared function beats N per-caller patches. Patching only `grant_role!` (the path the issue's repro names) would leave direct `create!` and `grant!` still cryptic. **Preserves the invariant** — the validation and its unique index stay; only the words change (R3).
- **KTD-2 — Keep `grant_role!` raising; do *not* silently converge it onto `grant!`'s upsert.** The issue notes the semantic split (helper raises, `grant!` upserts) and floats "either an upsert or a clearer error." A test **seed** helper named with a bang that hits a uniqueness rule *should* fail loudly on a double-seed — silently replacing a subject's org role inside a test setup would violate least-astonishment and could mask a fixture that already granted a role. The right fix is therefore the **clearer error** (KTD-1), which now explicitly names `CurrentScope.grant!` as the upsert alternative for callers who actually want replace-semantics. Converging the helper onto upsert is called out as an Open Question, not silently chosen.
- **KTD-3 — Compute "which regex / which case" at the Guard raise site from data already in hand; add no catalog state.** The Guard already knows `controller_path` and `action_name`, and `CurrentScope.config.excluded_controllers` is right there. `config.excluded_controllers.find { |re| controller_path.match?(re) }` yields the matching regex (or `nil`). If `nil`, it's the not-routed case; the catalog's existing `grouped[controller_path]` can further tell "controller is routed but this action isn't" from "controller unknown" for a sharper remedy. This keeps the resolver untouched and the `PermissionCatalog` a pure route-derived read (R7) — no new instance state, no write, no purity risk. The one shared seam here *is* the Guard's raise block, and it already centralizes the check (`catalog.include?(permission)`), so enriching it in place fixes every gated controller at once.
- **KTD-4 — Enrich, never downgrade.** The excluded-controller branch must remain a `raise CurrentScope::ConfigurationError`. The temptation to "just deny" an unrouted key is wrong: a misconfiguration surfaced as a 403 is exactly the silent-failure the engine forbids. The message gets richer; the control flow is byte-for-byte the same (still raises, still before any allow). This is the security-relevant line — flagged so the implementer treats the raise as load-bearing.

---

## Implementation Units

### U1. Custom validation message on the one-org-role rule

- **Goal:** replace the bare `Subject has already been taken` with a message that names the rule and both remedies, at the model seam so all callers inherit it.
- **Requirements:** R1, R2, R3.
- **Dependencies:** none.
- **Files:** `app/models/current_scope/role_assignment.rb`, `test/models/current_scope/role_assignment_test.rb` (new — the `test/models/current_scope/` dir already holds `event_test.rb`, `role_test.rb`).
- **Approach:** add a `message:` to the existing uniqueness validation. Directional shape (words are the deliverable, tune for tone):
  ```ruby
  validates :subject_id,
            uniqueness: {
              scope: :subject_type,
              message: "already holds an org-wide role (one per subject by design). " \
                       "Use CurrentScope.grant! to replace it, or a scoped role for " \
                       "additive per-record access."
            }
  ```
  Because the message attaches to `subject_id`, the full error reads "Subject id already holds an org-wide role…". If the leading attribute-humanization reads awkwardly, keep the message self-contained (as above) so it stands on its own regardless of prefix. Do **not** touch the `after_save`/`after_destroy` memo-busting callbacks or the unique index — only the validation's `message:`.
- **Patterns to follow:** the engine's existing loud-but-actionable error style — `grant!`'s doc-comment framing (`lib/current_scope.rb:140-146`) and the `require_actor_method!` ConfigurationError, both of which name the rule *and* the fix in one breath.
- **Test scenarios:**
  - **Second grant, direct create!:** subject already has a RoleAssignment; `RoleAssignment.create!(subject:, role: other)` raises `ActiveRecord::RecordInvalid` whose message includes "org-wide role", "CurrentScope.grant!", and "scoped role" (input → expected substrings). This is the R1/R2 proof through the raw model path.
  - **Second grant, via `grant_role!` helper:** same subject through `grant_role!(subject, role: other)` raises with the same enriched message (R2 — helper inherits it; the helper is a thin `create!`).
  - **`grant!` still upserts (no raise):** `grant!(subject, role: a)` then `grant!(subject, role: b)` replaces the role, no exception, subject ends with role b (proves the message change didn't perturb the upsert path).
  - **First grant unaffected:** a subject's first `create!` succeeds normally.
  - **Invariant intact:** after the failed second `create!`, the subject still holds exactly one RoleAssignment (the original) — the uniqueness rule and index still bite (R3).
- **Verification:** new model test green; existing `test/grant_test.rb` still green (it asserts on class/behavior, not the old string); the invariant "exactly one org role per subject" holds.

### U2. Guard excluded-controller message: name the regex, split excluded vs not-routed

- **Goal:** turn the hedged static `ConfigurationError` into one that identifies the matching exclusion regex or states "not routed", with the right remedy per case — while still raising.
- **Requirements:** R4, R5, R6, R7, and KTD-3/KTD-4.
- **Dependencies:** none (independent of U1).
- **Files:** `lib/current_scope/guard.rb`, `test/integration/guard_test.rb` (extend the existing `"gating an excluded controller raises a configuration error"` test at line 72; add a not-routed case).
- **Approach:** in the `unless CurrentScope.catalog.include?(permission)` block (`guard.rb:41-46`), branch on `CurrentScope.config.excluded_controllers.find { |re| controller_path.match?(re) }`:
  - **Excluded (regex found):** message names the matching pattern and keeps the existing remedy tokens, e.g. `"\"#{permission}\" is excluded from the permission catalog by excluded_controllers pattern #{regex.inspect}, so it can never be granted. Either drop that pattern, or skip the gate here with skip_before_action :current_scope_check!."` — retains `excluded_controllers` and `skip_before_action :current_scope_check!` (R6).
  - **Not routed (no regex):** optionally sharpen using `CurrentScope.catalog.grouped[controller_path]` — if that key exists, the controller is catalogued but the **action** isn't routed ("controller X is routed but action Y isn't"); if not, the controller is unknown to the router. Message points at the routes, not at exclusions, e.g. `"\"#{permission}\" is not in the permission catalog: the controller#action is not routed. Add a route for it, or skip the gate with skip_before_action :current_scope_check!."`
  - Keep the whole thing a single `raise CurrentScope::ConfigurationError, <message>` — control flow unchanged (KTD-4). Extract the message-building into a small private helper (e.g. `catalog_miss_message(permission)`) if the branch makes `current_scope_check!` hard to read; keep it in `Guard`, not the catalog.
- **Execution note:** security-relevant seam (the fail-closed misconfiguration raise) — write/extend the failing assertion first (assert the new substrings) and confirm the branch still raises `ConfigurationError` in **both** cases before finalizing wording.
- **Patterns to follow:** the current message's own remedy phrasing (`guard.rb:42-45`); `PermissionCatalog#grouped` (`permission_catalog.rb:11-14`) for the routed-controller/unrouted-action distinction — read-only, no new catalog state (R7).
- **Test scenarios:**
  - **Excluded controller (existing test, enriched):** a gated request to an excluded controller (e.g. `webhooks`, already used at `guard_test.rb:72-78`) raises `ConfigurationError` whose message includes the controller#action key, the string `excluded_controllers`, the matching regex source, and `skip_before_action :current_scope_check!` (R4/R6). Raised even for a full-access Owner (unchanged).
  - **Not routed (new):** a gated `controller#action` key that matches no exclusion regex and isn't a route raises `ConfigurationError` whose message says "not routed" and does **not** falsely blame `excluded_controllers` (R5). (Construct via a dummy controller whose action isn't routed, or a key the catalog lacks.)
  - **Multiple regexes, correct one named:** with several `excluded_controllers` entries, the message names the *matching* pattern, not the first or all (R4) — the core of the "which one matched" nit.
  - **Still fail-closed:** in both branches the request raises rather than 200/403 — assert `assert_raises`, not a response code (KTD-4/R6).
- **Verification:** extended `guard_test.rb` green; the excluded case still contains every legacy token so any sandbox/host `assert_match` on `excluded_controllers` + `skip_before_action` keeps passing; not-routed case proven distinct.

### U3. Docs + CHANGELOG

- **Goal:** reflect both message improvements where the README already documents the loud behaviors and the helpers, and log the change.
- **Requirements:** R1–R6 (documentation of the delivered behavior).
- **Dependencies:** U1, U2 (document the final wording).
- **Files:** `README.md` (the "Two loud-by-design behaviors" note near the audit/loud-raise section ~L360-369; and the `grant_role!` / helper docs ~L510-533), `CHANGELOG.md` (under `## [Unreleased]`).
- **Approach:** (a) In the loud-behaviors note, update the excluded-controller sentence to mention it now names the matching pattern and distinguishes excluded from not-routed. (b) In the helper docs, add one line that a second org-wide grant for the same subject is refused with a message pointing to `CurrentScope.grant!` (replace) or scoped roles (additive) — so readers meet the guidance before they hit the error. (c) CHANGELOG: two `### Changed` bullets under `[Unreleased]` in the existing Keep-a-Changelog style ("Clearer error when …"). Do not invent a version bump — these are message-only, backward-compatible DX changes.
- **Test expectation:** none — documentation only.
- **Verification:** README renders; the helper section and loud-behaviors note match the shipped strings; CHANGELOG `[Unreleased]` carries both bullets.

---

## Scope Boundaries

**In scope:** the custom uniqueness `message:` on `RoleAssignment` (U1); the enriched excluded-controller `ConfigurationError` in `Guard` with regex identification and excluded-vs-not-routed wording (U2); tests for both; README + CHANGELOG (U3). Engine-only, message-only.

**Explicit non-goals / preserved design choices:**
- The **route-derived catalog** stays route-derived — no manual permission table, no new catalog persistence (KTD-3).
- The **one-org-role-per-subject** rule and its unique index stay; this is not an opening to multi-role (R3).
- The **fail-closed raise** on an uncatalogued gated controller stays a raise — never downgraded to a deny or allow (KTD-4).
- No new config knobs; opt-in SoD and the existing loud-by-design contract are untouched.

**Deferred to Follow-Up Work (tangential):**
- Converging `grant_role!` onto `grant!`-style upsert semantics (see Open Questions / KTD-2) — a behavior change, out of a message-polish scope.
- A broader audit of every engine error string for the same name-the-rule-and-fix standard (this issue does two; the rest can follow the pattern established here).
- Surfacing the "action routed but controller has other actions" hint in the management UI (this plan only enriches the raised message).

---

## Open Questions

- **Should `grant_role!` upsert instead of raise?** KTD-2 keeps it raising (a loud bang-seed helper) and makes the *message* name `grant!` as the upsert path. If the maintainer prefers the helper to be forgiving in test setup, that's a one-line switch to `find_or_initialize_by(...).tap { … update!(role:) }` — but it changes helper semantics and is left as a deliberate fork, not silently taken.
- **Attribute prefix on the validation message.** The message attaches to `:subject_id`, so Rails prepends "Subject id". If that humanized prefix reads poorly, the alternatives are validating on `:subject_type`/`:base` or accepting the self-contained wording as-is. Left for the implementer to eyeball against the rendered string; wording, not behavior.
- **Depth of the not-routed hint.** Minimal ("not routed") satisfies R5; the routed-controller/unrouted-action refinement via `catalog.grouped` is a nicety — include it only if it reads cleanly, otherwise the two-way excluded/not-routed split is sufficient.

---

## Cross-issue coupling

This issue is the DX-ergonomics sibling of the denial-message cluster — it shares the "a correct outcome with a confusing explanation" theme with the denial-behavior / engine-403 / denial-ergonomics work (the #23/#24/#39 group referenced in the workflow brief). If those plans are executed together, keep the **error-string voice consistent**: name the rule, then name the fix, in one breath — the standard U1/U2 establish here should be the template the denial-message plans reuse, so a host sees one coherent diagnostic tone across validation errors, `ConfigurationError`s, and `AccessDenied` reasons. No code coupling (different seams: this is the model validation + Guard raise; the denial cluster is `AccessDenied`/headers), so the plans compose additively and can land in any order.
