---
title: Denial Ergonomics (AccessDenied#permission, rescue_responses, denial-reason log) - Plan
type: feat
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/39
---

# Denial Ergonomics (`AccessDenied#permission`, `rescue_responses`, denial-reason log) - Plan

## Goal Capsule

- **Objective:** close three small, independent papercuts every host hits when it builds a 403 experience on top of the gem's denial: (1) `AccessDenied` exposes the denied **permission** only inside `#message`, so branded-403 pages and error trackers must string-parse prose to get a stable key; (2) `CurrentScope::AccessDenied` is **not** registered in `config.action_dispatch.rescue_responses`, so any denial that escapes a Guard-wrapped controller becomes a production **500** instead of a **403**; (3) the rescued-denial **log line carries no machine-readable reason**, so server-side triage can't tell `:no_grant` from `:sod_veto` — the reason travels only on a response header logs never capture.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `docs/ROADMAP.md`, `resources/DESIGN.md` if present). The engine invariants are **immutable and untouched by this issue**: resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **PURITY** (no writes, no per-decision state, ambient `CurrentAttributes` read only via `Current`). This is a **denial-surface** change only — it changes *how a denial is described and classified*, never *who is denied* or the decision that denied them. No resolver, catalog, or `Current` code is touched.
- **Fail-closed note (load-bearing):** registering `rescue_responses → :forbidden` **strengthens** the fail-closed posture rather than weakening it. It never turns a deny into an allow — the exception has already prevented the action. It only reclassifies an *escaped* denial from a misleading 500 into the correct 403. A denial that reaches Rails' exception handler was already a denial.
- **Stop conditions — surface rather than guess if:**
  - (a) any change would alter *who* is denied, the decision order, or make the resolver do work it doesn't do today;
  - (b) making `#message` stop equalling the permission key would break the documented branded-403 recipe (backward-compat: `#message` must stay the permission string this release — see KTD-1);
  - (c) the `rescue_responses` registration does not actually land in `ActionDispatch::ExceptionWrapper.rescue_responses` at boot (initializer ordering — see U2 verification and Open Questions), i.e. the probe from the issue still returns `:internal_server_error`.

---

## Product Contract

> **Product Contract preservation:** enhancement off a filed issue (#39), no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Requirements are derived from the issue's three verified findings and re-checked against `lib/current_scope.rb:18-25`, `lib/current_scope/guard.rb:53-61`, `lib/current_scope/mutation_guard.rb:29-53`, and `lib/current_scope/engine.rb` on 2026-07-15.

### Summary

Three additive, backward-compatible denial-ergonomics fixes. Add `AccessDenied#permission` (plus `#record` and `#subject`, populated where the raising seam has them) so hosts render 403 pages off stable data, not a parsed message string. Register `"CurrentScope::AccessDenied" => :forbidden` in `rescue_responses` from the engine so a denial that escapes a Guard-wrapped controller returns a 403, not a 500. Emit one server-side log line on every rescued denial carrying the permission and the machine-readable reason, so `log/*.log` shows what the `X-Current-Scope-Reason` header shows. No decision behavior changes.

### Problem Frame

Every adopting host builds its own 403 experience on top of `CurrentScope::AccessDenied`, and each of the three gaps is a papercut multiplied across all of them:

1. **Permission only in `#message` (minor, enhancement — scenario 05).** `AccessDenied` carries `attr_reader :reason` but the permission key rides in `#message` (the positional arg at both raise sites: `guard.rb:57`, `mutation_guard.rb:34`). A branded-403 page or error tracker that wants the stable key must read `e.message` **as data** — fragile the day the message becomes prose. The Guard already has the `record` and the `subject` in hand at raise time (`guard.rb:48,53-56`) and drops both; a rich 403 ("you can't `approve` *this* Report") can't be built.
2. **No `rescue_responses` registration (minor, enhancement — scenario 05).** `ActionDispatch::ExceptionWrapper.rescue_responses["CurrentScope::AccessDenied"]` returns `:internal_server_error` (issue Probe D). Inside a Guard/MutationGuard controller the auto-installed `rescue_from` (`mutation_guard.rb:24`) catches the denial and renders 403 — fine. But a denial raised **outside** that rescue — a PORO using `CurrentScope.allowed?`, a controller that includes only `Context`, a host that deliberately re-raises — escapes to Rails' exception handler and becomes a **500**. One engine line makes the *class* map to 403 everywhere, independent of who catches it.
3. **Reason absent from the log (papercut, dx — scenario 01).** On a rescued denial, the dev log shows Rails' own `rescue_from handled CurrentScope::AccessDenied (posts#index) … Completed 403 Forbidden` — the permission is visible but the **reason is not**. `current_scope_denied` (`mutation_guard.rb:49-53`) sets the reason on the response header only, and server logs never capture response headers. Log-based triage can't distinguish a missing grant from an SoD veto from an impersonation gate.

### Requirements

- **R1.** `AccessDenied` exposes `#permission` — the denied permission key as a dedicated read accessor, independent of `#message`. For backward compatibility this release, `#message` still returns the permission key at both existing raise sites (the branded-403 recipe keeps working); `#permission` is the stable API going forward.
- **R2.** `AccessDenied` exposes `#record` and `#subject`, populated with the record and the effective subject when the raising seam has them (the Guard permission gate has both), and `nil` when it does not (the MutationGuard impersonation gate loads no record). The `nil` case is documented — a `nil` record on a denial is itself meaningful (a collection/gate denial, not a record-level one).
- **R3.** The two existing raise sites (`guard.rb`, `mutation_guard.rb`) populate the new attributes from data already in scope — no new lookups, no new failure modes. Absent/failed hooks never turn into a raise *from the exception constructor* (fail-safe: the constructor only stores what it's given).
- **R4.** `ActionDispatch::ExceptionWrapper.rescue_responses["CurrentScope::AccessDenied"]` resolves to `:forbidden` after the engine loads, so a denial escaping any Guard rescue renders 403, not 500. This is registered by the engine — no host wiring required.
- **R5.** On every rescued denial, `current_scope_denied` emits exactly one server-side log line carrying the permission and the reason (e.g. `[CurrentScope] denied posts#index (no_grant) → 403`), in addition to (not instead of) the existing `X-Current-Scope-Reason` header.
- **R6.** All three changes are additive and default-on-but-inert-where-it-matters: no decision changes, no host opt-in, and the only observable behavior change for an upgrader is the intended one — an escaped denial now 403s instead of 500ing, and a new INFO log line appears on denials.

---

## Key Technical Decisions

- **KTD-1 — `#permission` is a first-class attribute derived from the message for backward compat; `#message` stays the key this release.** The constructor gains keyword args (`permission:`, `record:`, `subject:`) and stores `@permission = permission || message`. Both raise sites already pass the permission key as the positional `message`, so `#permission` is populated **without changing `#message`** — the documented branded-403 recipe that reads `e.message` keeps working (R1, backward compat). Raise sites are updated to pass `permission:` *explicitly* so intent is legible and a future release can make `#message` prose without breaking `#permission`. Directional signature: `initialize(message = nil, reason: nil, permission: nil, record: nil, subject: nil)`. **This is the "one seam" move** — the accessor lives on the exception, so every raise site (present and future, including #23's engine front-door raise) gets it for free rather than each caller threading the key separately.
- **KTD-2 — `#record`/`#subject` are populated where available, `nil` where not, and the `nil` is documented — not faked.** The Guard permission gate (`guard.rb`) has both `record` and `CurrentScope::Current.user` in scope and passes them. The MutationGuard impersonation gate (`mutation_guard.rb`) runs as a *separate, earlier* before_action that deliberately loads **no** record, so it passes `subject:` but leaves `record:` nil. We do **not** add a record lookup there to "fill the gap" — that would duplicate load logic, risk a second failure mode, and violate Least Astonishment (the impersonation gate is verb-based, not record-based). A `nil` record on an `:impersonation_gate` denial correctly signals "this was a gate denial, not a record-level one."
- **KTD-3 — `rescue_responses` is registered by the engine, mapping the class name string to `:forbidden`.** `rescue_responses` keys on the exception class **name** (a String), which is why the issue's probe uses the string form. Because `AccessDenied < StandardError`, the mapping is what reclassifies an escaped denial. This is registered from the engine so no host wires it. **It never allows an action** — the exception has already denied it — so the fail-closed posture is preserved and, for escaped denials, sharpened (500→403). The exact registration seam (a top-level `initializer` setting `config.action_dispatch.rescue_responses`) must be verified by the issue's probe at boot; initializer ordering relative to `action_dispatch.configure` is the one real risk (Open Questions, U2 verification).
- **KTD-4 — The log line lives in the single shared denial method, not at each raise site.** `current_scope_denied` (`mutation_guard.rb:49-53`) is the one place every Guard/MutationGuard denial is rendered and the reason header is set. Adding the log line there — reading `exception.permission` and `exception.reason` (now available from R1/R2) — covers both raise paths with one edit and keeps the log line structurally adjacent to the header it mirrors. It emits at `INFO` (a denial is expected control-flow, not an error) and guards `exception` being nil (the method signature allows it).
- **KTD-5 — No resolver/catalog/Current involvement; purity untouched.** All three changes live in the exception class, the engine initializer, and the controller denial seam. The resolver is not read, extended, or made to carry new state. Decision order and fail-closed behavior are byte-for-byte unchanged.

---

## Implementation Units

### U1. `AccessDenied#permission`, `#record`, `#subject` + populate both raise sites

- **Goal:** give `AccessDenied` dedicated accessors for the permission key, the record, and the subject, populated from data already in scope at each raise site, without changing `#message`.
- **Requirements:** R1, R2, R3.
- **Dependencies:** none.
- **Files:** `lib/current_scope.rb` (the `AccessDenied` class, ~L18-25), `lib/current_scope/guard.rb` (raise at L57), `lib/current_scope/mutation_guard.rb` (raise at L34), `test/access_denied_test.rb` (new — unit test for the exception), `test/integration/guard_test.rb` and `test/integration/impersonation_gate_test.rb` (assert the rescued exception's attributes on the two real paths).
- **Approach:** extend the constructor to `initialize(message = nil, reason: nil, permission: nil, record: nil, subject: nil)`; add `attr_reader :permission, :record, :subject` alongside the existing `:reason`; store `@permission = permission || message` (KTD-1 backward compat). Update the class doc comment to describe the new attributes and the `nil`-record semantics (KTD-2). In `guard.rb:57`, raise `AccessDenied.new(permission, reason: reason, permission: permission, record: record, subject: CurrentScope::Current.user)`. In `mutation_guard.rb:34`, raise with `permission: "#{controller_path}##{action_name}"` and `subject: CurrentScope::Current.user`, leaving `record:` unset (nil). No new record load in the mutation guard.
- **Patterns to follow:** the existing `attr_reader :reason` + keyword-constructor shape already in `AccessDenied`; the way `guard.rb` already reads `record` and `CurrentScope::Current.user` at the decision call (L48, L53-56).
- **Test scenarios:**
  - `AccessDenied.new("posts#index", reason: :no_grant)` → `#permission == "posts#index"`, `#message == "posts#index"`, `#record == nil`, `#subject == nil` (backward-compat: message still the key).
  - `AccessDenied.new("x", reason: :no_grant, permission: "reports#approve", record: <report>, subject: <user>)` → each accessor returns exactly what was passed; `#message == "x"` (proves `#permission` is decoupled from `#message`).
  - **Guard path (integration):** an ungranted member action rescued → the raised exception's `#permission` is the controller#action key, `#record` is the record `current_scope_record` returned, `#subject` is `Current.user`, `#reason == :no_grant`.
  - **Impersonation-gate path (integration):** a non-GET while impersonating → `#permission` is the key, `#reason == :impersonation_gate`, `#record == nil` (no record loaded — KTD-2), `#subject` is `Current.user`.
  - **Backward compat:** the existing branded-403 pattern reading `e.message` still yields the permission key (no existing test regresses).
- **Verification:** the new unit test and the two integration assertions pass; existing `guard_test.rb` / `impersonation_gate_test.rb` still green; `#message` unchanged across the suite; RuboCop omakase clean.

---

### U2. Register `CurrentScope::AccessDenied` → `:forbidden` in `rescue_responses`

- **Goal:** an `AccessDenied` that escapes any Guard rescue renders 403, not 500, with no host wiring.
- **Requirements:** R4, R6.
- **Dependencies:** none (independent of U1, but lands in the same denial-ergonomics change).
- **Files:** `lib/current_scope/engine.rb`, `test/integration/rescue_responses_test.rb` (new — boot-time probe) or an assertion added to an existing engine-level integration test.
- **Approach:** add an engine `initializer` that sets `config.action_dispatch.rescue_responses["CurrentScope::AccessDenied"] = :forbidden` on the application config. Directional:

  ```ruby
  # directional — exact seam confirmed by the probe below
  initializer "current_scope.rescue_responses" do |app|
    app.config.action_dispatch.rescue_responses["CurrentScope::AccessDenied"] = :forbidden
  end
  ```

  Keep it beside the existing `config.to_prepare` block. If the probe shows the mapping hasn't landed (ordering vs. `action_dispatch.configure`), pin the initializer with `before: "action_dispatch.configure"` (Open Questions). This is purely additive — it changes classification of *escaped* denials only; Guard/MutationGuard's own `rescue_from` still runs first for in-controller denials.
- **Patterns to follow:** the engine's existing single-responsibility `config.to_prepare` block; standard Rails-engine `initializer` registration of `rescue_responses` (the same mechanism Rails uses for `ActiveRecord::RecordNotFound → :not_found`).
- **Test scenarios:**
  - **Probe (the issue's Probe D):** after boot, `ActionDispatch::ExceptionWrapper.rescue_responses["CurrentScope::AccessDenied"]` (or the dummy app's `config.action_dispatch.rescue_responses[...]`) resolves to `:forbidden`, not `:internal_server_error`.
  - **Escaped denial (integration):** a controller that raises `CurrentScope::AccessDenied` **without** a Guard rescue in scope (e.g. `test/dummy`'s `bare_controller` re-raising, or a dedicated dummy action) returns HTTP **403**, not 500.
  - **In-controller denial unchanged:** a normal Guard denial still returns 403 via `current_scope_denied` (the rescue_from wins first) — no double-handling, header still set.
- **Verification:** the probe returns `:forbidden`; the escaped-denial request returns 403; existing Guard/MutationGuard denial tests unchanged; RuboCop clean. If the probe returns `:internal_server_error`, apply the `before:` ordering pin and re-verify (do not ship without the probe green — Stop condition (c)).

---

### U3. Emit the denial reason (and permission) in the server log

- **Goal:** every rescued denial writes one log line carrying the permission and the machine-readable reason, mirroring the `X-Current-Scope-Reason` header for log-based triage.
- **Requirements:** R5, R6.
- **Dependencies:** U1 (reads `exception.permission` and `exception.reason`; `#reason` already exists, `#permission` arrives in U1).
- **Files:** `lib/current_scope/mutation_guard.rb` (`current_scope_denied`, L49-53), `test/integration/guard_test.rb` (assert the log line on a denial).
- **Approach:** in `current_scope_denied`, before/after setting the header, emit `Rails.logger&.info("[CurrentScope] denied #{exception&.permission} (#{exception&.reason}) → 403")`. Guard `exception` being nil (the method signature allows `exception = nil`). Keep it INFO — a denial is expected control-flow, not an error (KTD-4). Do not remove or change the header line.

  > **Coupling note:** issue #23 refactors `current_scope_denied` to extract a `render_access_denied` body seam. The log line is orthogonal (it reads the exception, doesn't render). If #23 lands first, add the log line inside the restructured method; if this lands first, #23 preserves the log line. See Cross-issue coupling.
- **Patterns to follow:** the existing `Rails.logger&.warn(...)` nudge in `guard.rb`'s `nudge_on_nil_sod_record` (same `[CurrentScope] …` prefix, same `Rails.logger&.` nil-safe call style).
- **Test scenarios:**
  - **Reason present:** a `:no_grant` denial through Guard writes a log line containing the permission key and `no_grant`. (Assert via a captured logger / `assert_logged` helper or a `StringIO` logger in the dummy.)
  - **Impersonation gate:** an `:impersonation_gate` denial logs that reason and the permission key.
  - **Nil-safe:** `current_scope_denied` called with no exception (defensive path) does not raise and logs a line with blank fields rather than crashing.
  - **Header still set:** the existing `X-Current-Scope-Reason` assertion in `guard_test.rb` continues to pass (log is additive, not a replacement).
- **Verification:** the log-line assertions pass; header behavior unchanged; no denial path raises from logging; RuboCop clean.

---

### U4. Document the denial-ergonomics surface

- **Goal:** document the new `AccessDenied` attributes, the `rescue_responses` guarantee, and the denial log line, so hosts build 403 experiences off stable API.
- **Requirements:** R1-R5 (documentation of the shipped behavior).
- **Dependencies:** U1-U3.
- **Files:** `README.md` (the denial section around L486-488), `CHANGELOG.md`, `STATUS.md` / `docs/ROADMAP.md` (mark landed).
- **Approach:** extend the denial paragraph (README L486-488) to (a) list `#permission`, `#record`, `#subject`, `#reason` as the `AccessDenied` accessors, noting `#record`/`#subject` are `nil` on gate denials that load no record; (b) state that the gem registers `CurrentScope::AccessDenied → 403` in `rescue_responses`, so an escaped denial 403s rather than 500s; (c) note the server-side denial log line and its format. Show a two-line branded-403 snippet using `e.permission`/`e.reason` (not `e.message`). Add a CHANGELOG entry under the current unreleased heading. Coordinate wording with #24 (denial-behavior docs) so the two sections compose rather than duplicate — this issue documents the *new accessors and classification*; #24 documents the *default blank-403 body and the override seam*.
- **Test expectation:** none — documentation only.
- **Verification:** README renders; the branded-403 snippet reads off `#permission`/`#reason`; CHANGELOG and STATUS updated; no duplication with the #24 section.

---

## Scope Boundaries

**In scope:** the three exception accessors (`#permission`/`#record`/`#subject`) and their population at the two raise sites; the `rescue_responses → :forbidden` engine registration; the denial-reason log line in `current_scope_denied`; tests for each; docs.

**Out of scope / explicit non-goals:**
- **No change to `#message`.** It stays the permission key this release (KTD-1). Making it prose is a future, separately-versioned change.
- **No record load added to the MutationGuard impersonation gate.** `#record` stays `nil` there by design (KTD-2).
- **No change to the denial body.** Whether a denial renders a blank `head :forbidden` or a page is issue #23/#24's concern, not this one. This issue does not render anything new.
- **No resolver, catalog, decision-order, or `Current` change.** None of the three fixes need one.
- **No host-configurable log level/format knob.** A single INFO line is enough; a config surface for it is speculative (add only if a real host asks).

### Deferred to Follow-Up Work

- Making `#message` human prose (with `#permission` as the stable key) — a deliberate future breaking-ish change, gated on the branded-403 recipe having migrated to `#permission`.
- A structured/tagged-logging variant of the denial line (e.g. `Rails.logger.tagged` or a `details:` hash) if hosts want machine-parseable denial logs.
- Exposing `#actor` on `AccessDenied` (the real actor under impersonation) — cheap, but no filed need yet; add when a host wants to render "acting as" in its 403.

---

## Open Questions

- **`rescue_responses` initializer ordering.** Does a plain engine `initializer` setting `config.action_dispatch.rescue_responses` land before `ActionDispatch::ExceptionWrapper` freezes its map at boot, or must it be pinned `before: "action_dispatch.configure"`? U2's probe is the arbiter — the plan ships whichever form makes the probe return `:forbidden`. (This is the one genuine unknown; everything else is mechanical.)
- **Log level.** INFO is proposed (a denial is expected control flow). If a maintainer prefers denials at WARN for visibility in quieter log configs, that's a one-word change — flag before release.
- **`#subject` on the MutationGuard path — effective subject vs. actor.** The impersonation gate denies because a real actor stands behind a different subject. `#subject` is set to `Current.user` (the effective subject) for consistency with the Guard path; if a 403 page wants to say "you (the real actor) can't mutate while impersonating," it needs the actor, which is deferred (`#actor`, above). Confirm the effective subject is the right default here.

---

## Cross-issue coupling

This issue is the third member of the **denial-surface cluster** — it must compose with two siblings that touch the same seams:

- **#23 (engine management-UI 403 routes through AccessDenied/reason) — `docs/plans/2026-07-15-005-fix-engine-403-no-reason-plan.md`.** #23 adds a **new raise site** (`require_full_access!` raising `AccessDenied.new(..., reason: :not_full_access)`) and **refactors `current_scope_denied`** to extract a `render_access_denied` body seam. Both plans edit `AccessDenied` (this one adds attributes; #23 adds the `:not_full_access` reason to the vocabulary comment) and both edit `current_scope_denied` (this one adds a log line; #23 extracts the render tail). They are orthogonal in intent but **textually adjacent** — they will conflict on the same lines if landed blind. Recommended order: **#23 first** (it restructures `current_scope_denied` and the `AccessDenied` doc), then this issue adds the log line into the restructured method and the attributes into the restructured class. #23's new raise site inherits `#permission` for free once this issue lands (KTD-1's whole point). If this lands first, #23 must preserve the log line and the new attributes.
- **#24 (document denial behavior end-to-end) — `docs/plans/2026-07-15-006-docs-denial-behavior-plan.md`.** Docs-only; deliberately leaves `current_scope_denied` unchanged and documents the *current* blank-403 body + override seam + the `rescue_from StandardError` shadowing trap. This issue adds the *code* behind part of what #24 describes (new accessors, 403 classification, log line). **U4 must coordinate with #24's README section** so the two don't duplicate: #24 owns "what a denial renders and how to override it"; this issue owns "the accessors on the exception and the escaped-denial classification." #24's stop-condition (a) explicitly punts the "blank 403 is wrong" fix to #23/#39 — this plan is the #39 half of that punt for the *classification and diagnosability* aspects (not the body, which is #23).

No coupling to the #20↔#21 (permission_keys drop ↔ bypass_sod ungrantable) or #37↔#26 (report-only ↔ adoption-guide) clusters — those touch the catalog/resolver and docs respectively, not the denial surface.
