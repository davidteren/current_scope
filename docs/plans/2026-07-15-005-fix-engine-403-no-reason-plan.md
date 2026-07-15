---
title: Engine management-UI 403 routes through the AccessDenied/reason machinery - Plan
type: fix
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/23
---

# Engine management-UI 403 routes through the AccessDenied/reason machinery

## Goal Capsule

- **Objective:** make the engine's own front-door denial (`require_full_access!`) behave like every other denial the gem produces — carry a machine-readable `X-Current-Scope-Reason` header and render a one-line "you need a full-access role" page — instead of the current bare, bodyless `head :forbidden` that sits outside the reason machinery entirely.
- **Authority hierarchy:** this plan → the settled v0.1 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). The resolver decision order (SoD veto → full_access → org role → scoped role → deny), the fail-closed posture, one-org-role-per-subject, resolver **purity** (no writes, no per-decision state, ambient `CurrentAttributes` context read only via `Current`), and "only full_access subjects enter the management UI" are **immutable**. This is a papercut fix: it changes *how a denial is surfaced*, never *who is denied*. The full_access gate itself is untouched.
- **Root-cause framing (load-bearing):** the bug is not "the page is blank" — it is that `require_full_access!` renders its own denial with a private `head :forbidden`, drifting from the shared `current_scope_denied` path that sets the reason header for every other denial. The fix routes the engine's denial *through* that shared path and closes the drift so it cannot silently recur. One denial-rendering seam, not two.
- **Stop conditions:** stop and surface rather than guess if (a) any change would alter *who* gets into the management UI (the fix is presentation-only — the `full_access?` check stays byte-for-byte), (b) rendering a body for the engine denial would change the response body of **host** Guard/MutationGuard denials (those must stay bodyless `head :forbidden` — see KTD-3), or (c) the new reason symbol collides with or reshapes an existing one.

---

## Product Contract

> **Product Contract preservation:** bug fix off a filed issue (#23), no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Requirements below are derived from the issue's verified findings and the gem's existing denial contract.

### Summary

`require_full_access!` (`app/controllers/current_scope/application_controller.rb:24-26`) currently does `head :forbidden` directly. That bypasses the `CurrentScope::AccessDenied` → `current_scope_denied` machinery that already sets `X-Current-Scope-Reason` for Guard and MutationGuard denials, so the engine's front door is the one denial with a 0-byte body and no reason header. Route it through `AccessDenied` with a new documented reason `:not_full_access`, and render a minimal one-line explanation page (engine-UI only) in place of the bodyless head. The `full_access?` gate — who is denied — does not change.

### Problem Frame

The management UI is where an admin lands first, and it is deliberately closed to anyone without a full-access role (permissions are *granted* here, so it can't be gated by grantable permissions — only full_access enters). When a non-full-access subject (a Member, or a host-admin without a full-access role) opens `/current_scope/roles`, they get a blank 403 with no message and no `X-Current-Scope-Reason`. Every other denial the gem emits carries that header (`:sod_veto`, `:no_grant`, `:impersonation_gate`) and the README promises it. "Why can't I open the management UI?" is the most predictable first support question, and today the response gives the admin — and any diagnostic client or test — zero signal and no way forward. The `MutationGuard` concern the engine controller already includes *has* the reason-surfacing rescue (`current_scope_denied`); `require_full_access!` simply never reaches it.

### Requirements

- **R1.** A non-full-access (or anonymous) request to any engine management-UI action responds `403 Forbidden` — unchanged from today. *Who* is denied does not change.
- **R2.** That 403 carries `X-Current-Scope-Reason: not_full_access`, consistent with the header set for `:sod_veto` / `:no_grant` / `:impersonation_gate` denials.
- **R3.** `:not_full_access` is a documented member of the `AccessDenied#reason` vocabulary (code comment on `AccessDenied`, README denial section).
- **R4.** The engine 403 renders a minimal human-readable page stating the area requires a full-access role (non-empty body), replacing the current 0-byte body.
- **R5.** Host-app denials rendered through `Guard` / `MutationGuard` (`current_scope_denied`) keep their existing bodyless `head :forbidden` behavior — the rendered page is engine-UI-only. No host upgrader sees a changed denial body.
- **R6.** The reason header is written in exactly one place. After this fix there is no denial path that surfaces (or fails to surface) the reason independently of `current_scope_denied`.

---

## Key Technical Decisions

- **KTD-1 — Route the engine denial through `AccessDenied`, don't patch `head :forbidden` in place.** The smallest *correct* fix is not "add a header line next to the existing `head :forbidden`" — that would leave a second, parallel denial-rendering site and re-create the exact drift that caused this bug. Instead, `require_full_access!` raises `CurrentScope::AccessDenied.new("#{controller_path}##{action_name}", reason: :not_full_access)`. `ApplicationController` already `include`s `MutationGuard`, whose `included do … rescue_from CurrentScope::AccessDenied, with: :current_scope_denied end` catches exceptions raised in before_actions. So the header (R2) comes **for free** through the existing shared path — no new header-writing code. This is the "one guard in the shared function beats N per-caller patches" move.
- **KTD-2 — The reason-header write stays in exactly one method; the response *body* becomes an overridable seam.** `current_scope_denied` (in `MutationGuard`) keeps sole ownership of `response.headers["X-Current-Scope-Reason"] = reason.to_s` (R6). Its body-rendering tail — today an inline `head :forbidden` — is extracted into a private `render_access_denied` that defaults to `head :forbidden`. Host controllers inherit the default unchanged (R5). The engine `ApplicationController` overrides *only* `render_access_denied` to render the explanation page. This is a one-line template-method seam with exactly one override — justified precisely because it keeps the header in one place and structurally prevents the denial-body from drifting away from the reason machinery again. (Alternative rejected: register a second `rescue_from CurrentScope::AccessDenied` on `ApplicationController` — Rails would let it win over MutationGuard's, but it would duplicate the header-write line and re-open the drift this fix exists to close.)
- **KTD-3 — The rendered page is engine-UI-only, never folded into the shared denial.** `current_scope_denied` runs inside **host** controllers too (Guard/MutationGuard are mixed into host app controllers). Rendering an engine view or an HTML body from that shared path would astonish host apps: their denials would suddenly emit an engine-styled body into their own controller/response contract, and there's no host layout/view guarantee. Host denials therefore stay bodyless `head :forbidden` (R5); only the engine overrides the seam. This is Least Astonishment applied to the shared concern.
- **KTD-4 — The explanation page renders with `layout: false` (no engine chrome), HTML-only.** The engine layout (`layouts/current_scope/application.html.erb`) hardcodes a "full access" badge and a nav whose every link would itself 403 for this visitor. Rendering the denial inside that shell would be misleading and offer only dead links. A small self-contained view with `status: :forbidden, layout: false` is both lazier and less astonishing. The engine override renders the page **only when `request.format.html?`** and falls back to the default bare `head :forbidden` for a non-HTML `Accept`. The engine routes emit no JSON (`config/routes.rb` has no format branch), so an *unconditional* `render` would raise `ActionView::MissingTemplate` on a non-HTML `Accept` and turn a diagnostic/API client's clean 403 into a 500 — contradicting R1 on exactly the surface it targets. Non-HTML denials therefore stay a bare 403 that *still* carries the reason header (written in `current_scope_denied` before the body seam runs, so R2 holds). (Directional: a one-paragraph page, no new CSS pipeline dependency.)
- **KTD-5 — Purity is not touched.** `full_access?` is a pure resolver read and stays exactly as-is; the fix lives entirely in the controller/denial layer. No resolver, catalog, or `Current` change. The fail-closed posture is preserved: an anonymous or non-full-access subject is still denied, only now legibly.

---

## Implementation Units

### U1. Route `require_full_access!` through `AccessDenied` with `:not_full_access`

- **Goal:** replace the private `head :forbidden` in the engine front door with a raise that lands in the existing shared denial path, so the reason header is surfaced.
- **Requirements:** R1, R2, R3.
- **Dependencies:** none.
- **Files:** `app/controllers/current_scope/application_controller.rb`, `lib/current_scope.rb` (extend the `AccessDenied` doc comment's reason list), `test/integration/management_ui_test.rb` (extend the existing "closed to anonymous and non-full-access subjects" test).
- **Approach:** in `require_full_access!`, keep the `full_access?` check verbatim; on failure raise `CurrentScope::AccessDenied.new("#{controller_path}##{action_name}", reason: :not_full_access)` instead of `head :forbidden`. `ApplicationController` already `include`s `MutationGuard`, so its `rescue_from CurrentScope::AccessDenied` catches the before_action raise and `current_scope_denied` sets the header. Add `:not_full_access` to the `AccessDenied` reason list in the `lib/current_scope.rb` doc comment (currently `:sod_veto, :no_grant, :impersonation_gate`).
- **Patterns to follow:** the raise-with-reason form already used in `mutation_guard.rb:34` (`AccessDenied.new("#{controller_path}##{action_name}", reason: :impersonation_gate)`) and `guard.rb:57`.
- **Test scenarios (test-first — this is a security/denial path):**
  - Non-full-access subject GETs `current_scope.roles_url` → `assert_response :forbidden` **and** `assert_equal "not_full_access", response.headers["X-Current-Scope-Reason"]`. (Directly inverts the issue's `assert_nil` probe.)
  - Anonymous GET → `:forbidden` + `not_full_access` header.
  - Full-access subject → `:success`, no reason header (regression guard — the gate still admits the right people).
  - A mutation (e.g. `patch role_url`) by a non-full-access subject still denies with the header (defense-in-depth: MutationGuard's impersonation gate and this full_access gate compose without clobbering each other's reason — assert the full_access denial wins for a non-impersonated non-full-access subject).
- **Verification:** the extended `management_ui_test.rb` is green; the header assertion that was `assert_nil` in the sandbox probes now reads `not_full_access`; full-access access is unchanged; RuboCop omakase clean.

---

### U2. Extract the denial-body seam and render the engine explanation page

- **Goal:** give the engine 403 a minimal readable body while keeping host denials bodyless and the reason-header write in one place.
- **Requirements:** R4, R5, R6.
- **Dependencies:** U1.
- **Files:** `lib/current_scope/mutation_guard.rb` (extract `render_access_denied`), `app/controllers/current_scope/application_controller.rb` (override `render_access_denied`), `app/views/current_scope/errors/forbidden.html.erb` (new minimal view), `test/integration/management_ui_test.rb` (body assertions), `test/controllers/` or `test/integration/` host-denial regression (assert host denial body stays empty — can extend an existing MutationGuard/impersonation test, e.g. `test/impersonation_boundary_test.rb`).
- **Approach:**
  - In `MutationGuard#current_scope_denied`, keep the header write, then replace the trailing `head :forbidden` with a call to a new private `render_access_denied` whose default body is `head :forbidden`. Host controllers inherit the default unchanged (R5, R6 — header still written exactly once, in `current_scope_denied`).
  - In the engine `ApplicationController`, override `render_access_denied` to render the page **only for HTML**, falling back to the bare default otherwise: `return head :forbidden unless request.format.html?` then `render "current_scope/errors/forbidden", status: :forbidden, layout: false`. The engine is HTML-only (`config/routes.rb` declares no JSON), so an unconditional render would raise `ActionView::MissingTemplate` on a non-HTML `Accept` and regress that request's clean 403 to a 500 (R1). The reason header is already set in `current_scope_denied` before this seam runs, so the non-HTML bare 403 still carries it (R2).
  - Add `app/views/current_scope/errors/forbidden.html.erb`: a self-contained minimal page (heading + one line: this area requires a full-access role), no dependency on the engine layout/nav (KTD-4). Directional copy only — no new asset pipeline wiring.
  - Directional seam sketch (authoritative prose above):
    ```
    # mutation_guard.rb
    def current_scope_denied(exception = nil)
      reason = exception.respond_to?(:reason) ? exception.reason : nil
      response.headers["X-Current-Scope-Reason"] = reason.to_s if reason
      render_access_denied
    end
    def render_access_denied = head :forbidden   # host default; engine overrides
    ```
- **Patterns to follow:** the existing `current_scope_denied` structure in `mutation_guard.rb:49-53`; engine view conventions under `app/views/current_scope/`.
- **Test scenarios:**
  - Non-full-access GET to the engine UI → `:forbidden`, `not_full_access` header, **and** `response.body` is non-empty and contains the "full-access role" explanation (inverts the issue's "asserts empty body" probes in scenarios 05/06).
  - Host-app denial regression: a MutationGuard/impersonation denial (host controller) still yields an **empty** body + its own reason header — proving the rendered page did not leak into the shared path (R5).
  - The engine forbidden page renders **without** the engine layout (no "full access" badge, no nav — assert the badge text is absent), so a locked-out visitor isn't shown a full-access chrome or dead nav links.
  - Non-HTML `Accept` to the engine UI (e.g. `get current_scope.roles_url, headers: { "Accept" => "application/json" }`) by a non-full-access subject → `:forbidden` (**not** `:internal_server_error`), `not_full_access` header, empty body — the HTML-only gate returns a bare 403, never a `MissingTemplate` 500 (R1).
- **Verification:** engine 403 body is present and explanatory; host denials remain bodyless; header still written once; full test suite green; RuboCop clean.

---

### U3. Documentation

- **Goal:** record `:not_full_access` in the public denial vocabulary and note the engine front-door page.
- **Requirements:** R3.
- **Dependencies:** U1, U2.
- **Files:** `README.md` (denial-reason section, ~line 486), `CHANGELOG.md`.
- **Approach:** add `:not_full_access` to the README's documented reason list (`:sod_veto`, `:no_grant`, `:impersonation_gate`) with a one-line note that the management UI's own full-access gate now surfaces it and renders a minimal explanation page instead of a bare 403. Add a CHANGELOG bug-fix entry (behavior change upgraders see: the engine 403 now carries a reason header and a body; host denials unchanged).
- **Patterns to follow:** the existing denial paragraph in `README.md` and the CHANGELOG entry style.
- **Test expectation:** none — documentation only.
- **Verification:** README denial list includes `:not_full_access`; CHANGELOG notes the fix and that host denial bodies are unaffected.

---

## Scope Boundaries

**In scope:** routing `require_full_access!` through `AccessDenied(:not_full_access)`; the `render_access_denied` seam in `MutationGuard`; the engine `ApplicationController` override; the minimal `errors/forbidden` view; tests; README + CHANGELOG.

**Out of scope / non-goals:**
- Changing *who* may enter the management UI — the `full_access?` gate is preserved verbatim (this is a presentation fix, not an authorization change).
- Any change to host-app denial bodies — they stay bodyless `head :forbidden` by deliberate design (KTD-3, R5).
- A "request access" / self-service escalation flow, a sign-in redirect, or any link back into the app from the denial page — the page is informational only.
- Restyling or theming the denial page beyond a minimal self-contained page (deliberately avoids the engine layout — KTD-4).
- Touching the resolver, catalog, or `Current` — none are involved.

### Deferred to Follow-Up Work

- A shared, host-overridable denial *view* (if a host ever wants to brand its own Guard denials) — today host denials are bodyless by contract; revisit only if requested.
- Localizing the denial copy (I18n) if/when the engine UI grows a translation layer.
- A "you're signed in as X but need a full-access role; contact an admin" richer message — needs a product decision on how much to reveal to a locked-out user.

---

## Open Questions

- **Reason symbol name.** `:not_full_access` is proposed (matches the issue and the existing snake-symbol style). Confirm over alternatives like `:full_access_required` before first release — it becomes part of the public header vocabulary.
- **Denial page layout.** Plan assumes `layout: false` with a self-contained view (KTD-4) to avoid the misleading "full access" badge and dead nav. If a maintainer prefers visual consistency, the alternative is a stripped engine layout variant — more code, some astonishment. Flagged, not blocking.

---

## Cross-issue coupling

This is the middle of the denial-ergonomics cluster the issue triage names: **denial-behavior (#24) ↔ engine-403 (#23, this plan) ↔ denial-ergonomics (#39)**. All three concern how a refusal is *surfaced*. This plan deliberately introduces the `render_access_denied` seam and reaffirms `current_scope_denied` as the single reason-header site (R6, KTD-2) — that seam is the natural composition point for #24/#39 (e.g. a richer denial body or host-overridable denial rendering). Those plans should build on this seam rather than adding parallel denial paths; if #39 lands a host-facing denial view, it extends `render_access_denied`, and if #24 broadens the reason vocabulary, it adds to the same `AccessDenied` list this plan documents. Sequence #23 first (it establishes the seam), then #24/#39 compose onto it.
