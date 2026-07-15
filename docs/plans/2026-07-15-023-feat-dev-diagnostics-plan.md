---
title: Dev-Mode Diagnostics for Silent Authorization Gaps - Plan
type: feat
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/41
---

# Dev-Mode Diagnostics for Silent Authorization Gaps - Plan

## Goal Capsule

- **Objective:** turn three documented-but-silent failure modes into loud dev/test log lines that cost nothing in production. (1) Flip `warn_on_nil_sod_record` to default **on in dev/test** so the SoD nil-record foot-gun tells on itself to the team that made it. (2) Add a parallel opt-in nudge for the mirror-image case on the **denial** path — a request 403s `:no_grant` while the subject holds a scoped grant that *would* have matched, but the gate saw a nil record. (3) Add a dev/test nudge when short-form `allowed_to?` derives a key that **diverges** from the gate the current controller actually enforces (the namespaced/custom-controller foot-gun the README already documents).
- **Authority hierarchy:** this plan → the settled v0.1 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). The resolver decision order (**SoD veto → full_access → org role → scoped role → deny**), fail-closed posture, one-org-role-per-subject, and the resolver's **purity** (no writes, no per-decision state, thread-shared, memoizable) are **immutable**. Everything here is a **log-only, dev/test-default diagnostic** — it never changes a single allow/deny outcome in any environment, and is silent in production by default.
- **Ambient context invariant preserved:** the two new nudges read the effective subject from `CurrentScope::Current`, exactly like the existing seams — no new threading of `current_user`.
- **Stop conditions:** stop and surface rather than guess if (a) a diagnostic would require the resolver to hold per-decision state or perform a write, (b) any change would alter a decision outcome or fire an exception where the code previously allowed/denied, (c) the divergence detector (#3) would nag *legitimate* cross-resource `allowed_to?` checks (see KTD-3 — the catalog-membership gate exists precisely to prevent this), or (d) the env-aware default would ever evaluate to "on" in production.

---

## Product Contract

> **Product Contract preservation:** enhancement cluster, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded in issue #41's three verified findings, each adversarially re-checked against gem source (`lib/current_scope/guard.rb`, `resolver.rb`, `lib/current_scope.rb`, `configuration.rb`).

### Summary

The engine already ships the *mechanism* for the first diagnostic (`config.warn_on_nil_sod_record` + `Guard#nudge_on_nil_sod_record`), but it is off by default and mentioned once in a README aside — the team that trips the foot-gun never enables the flag that would reveal it. This plan makes that nudge **default-on in development and test** (still off in production), and adds two sibling nudges built on the same pattern: a **denial-side** nudge for inert scoped grants, and a **key-derivation-divergence** nudge for the namespaced-controller case. All three are pure diagnostics — log-only, zero production cost, no decision ever changes.

### Problem Frame

All three failures are silent *in the bad direction* and all three burned the scenario apps:

- **Nil SoD record (04_sod_matrix):** `current_scope_record` returns nil on a member SoD action → the SoD veto is silently skipped → the initiator approves their own record (200). The nudge that catches this exists but is undiscoverable — off by default, one README aside. A team that made the mistake doesn't know to turn on the flag that reveals it.
- **Inert scoped grant (03_god_controller):** a god/legacy controller maps `action_name → model` by hand; forget to map an action → the hook returns nil → the scoped grant is inert → **403 `:no_grant`**. The fail direction is correct (closed), but there is *no* analog to the SoD nudge for plain scoped grants, so a mis-mapped action looks identical to a genuinely-ungranted one.
- **Key-derivation divergence (05_legacy_ui_overrides):** inside a controller whose path segment ≠ the record's route key (a `DashboardController` rendering `Report`s), short-form `allowed_to?(:show, report)` derives `reports#show` while the gate enforces `dashboard#show` — a link shows then 403s, or a working control is hidden. `CurrentScope.permission_key` already computes the exact condition; today it falls through silently.

### Requirements

- **R1.** `config.warn_on_nil_sod_record` defaults to **on in development and test, off in production** (and off whenever Rails is not loaded). A host may still force it either way. The existing nudge behavior and message are unchanged; only the default flips.
- **R2.** A new `config.warn_on_inert_scoped_grant` (same env-aware default) makes the Guard log a nudge when, and only when, a request is **denied with reason `:no_grant`**, the gate saw a **nil record**, and the subject **holds a scoped grant** whose role grants that permission key. It fires at the gate seam (never on advisory `allowed_to?`/`scope_for`), changes no outcome, and the deny still raises exactly as before.
- **R3.** A new `config.warn_on_cross_controller_derivation` (same env-aware default) makes `CurrentScope.permission_key` log a nudge when short-form key derivation **diverges** from the current controller's gate: a bare action + a record whose `route_key` ≠ the controller path's last segment, **and** `"{controller_path}#{action}"` is a real catalog entry (so the current controller genuinely gates that action — distinguishing the foot-gun from a legitimate cross-resource check). The derived key is unchanged; only a warning is added.
- **R4.** Every diagnostic is **log-only**. No decision outcome, exception, header, or audit row changes in any environment as a result of this work. With every flag off, behavior is byte-for-byte the v0.2.0 baseline.
- **R5.** The new nudges reuse the established resolver query surface (`roles_granting`) rather than duplicating grant-matching logic — one definition of "does a role grant this key", shared by the gate, `scope_for`, and the new diagnostic.
- **R6.** The initializer template, README, and STATUS/ROADMAP document all three diagnostics and the env-aware default, so the discoverability gap the issue names is actually closed (a named flag in the initializer teaches the failure mode exists).

---

## Key Technical Decisions

- **KTD-1 — Env-aware default via one shared helper, three named flags (not an umbrella).** The three flags share an env-aware default: on in dev/test, off in prod, off with no Rails. A single private `Configuration#diagnostics_default_on?` (`defined?(Rails) && Rails.respond_to?(:env) && Rails.env.local?` — `local?` = development|test, available on the Rails 8.1 floor) computes it; each flag reads it in `initialize`. **Three named flags, not one `config.diagnostics` umbrella,** because *discoverability is the entire point of the issue* — `config.warn_on_inert_scoped_grant = false` sitting in the generated initializer teaches the reader that the failure mode exists; a generic `config.diagnostics` does not. The umbrella is noted as an Open Question, not adopted.
- **KTD-2 — The two new nudges live at their seams, never in the resolver.** `nudge_on_inert_scoped_grant` lives in `Guard#current_scope_check!` (the one place a *real* gated deny happens, never advisory), exactly mirroring the existing `nudge_on_nil_sod_record`. The derivation nudge lives in `CurrentScope.permission_key` (the one place `route_key` and `controller_path` are both in hand). This is the "one guard in the shared function" principle: `permission_key` is the single seam every `allowed_to?`/`scope_for` derivation flows through, so the check is written once, not per-caller. **The resolver stays pure** — it gains only a read-only query helper (below), no state, no writes.
- **KTD-3 — The divergence detector gates on catalog membership to avoid nagging legitimate cross-resource checks.** The naive condition ("bare action + record whose route_key ≠ controller path's last segment") is true for *every* legitimate cross-resource check too (an `allowed_to?(:approve, report)` from a projects view derives `reports#approve` — correct, not a foot-gun). The distinguishing signal: the foot-gun is when the **current controller actually gates this action** under its own path. So the nudge fires only when `catalog.include?("{controller_path}#{action}")` — i.e. the page's gate really is `{controller_path}#{action}` while the view derived `{route_key}#{action}`. This keeps false positives to the rare case of a controller that routes `#approve` *and* hosts a cross-resource approve check for a different model (documented residual, acceptable dev-only noise).
- **KTD-4 — New resolver helper `scoped_grant_exists?(subject:, permission:)` is a pure read, consistent with `scope_for`.** The inert-grant nudge needs "does the subject hold *any* scoped grant for this key, on any record?". That is a query (like `org_role`, `scope_for`, `scoped_grant?` already are) — it holds no per-decision state and writes nothing, so it does not touch the purity contract. It reuses `roles_granting(permission)` (R5). Called only from the dev nudge path, so it costs nothing when the flag is off. **Residual false positive (parallel to KTD-3):** because the helper deliberately omits the `resource:` filter, the nudge can't distinguish a *forgotten member-action mapping* (the real foot-gun) from a *legitimate collection action* whose key a scoped role happens to list — both surface as `:no_grant` + nil record + `scoped_grant_exists? == true`. The seam has no member-vs-collection signal to tighten on (that is exactly the ambiguity `nudge_on_nil_sod_record` lives with), so U2 accepts the false positive and *hedges the message* rather than trying to suppress it — accepted dev-only noise, covered by the collection-action test scenario in U2.
- **KTD-5 — Behavior-change surface is exactly one line, and it is safe.** The only default that flips (R1) is a log-only nudge; an upgrader running dev/test will now see `[CurrentScope]` warnings they didn't before. That is the intended win, not a regression. Called out in the CHANGELOG (U4). No production log volume change (default off in prod).

---

## Implementation Units

### U1. Config: env-aware default + two new diagnostic flags

- **Goal:** flip `warn_on_nil_sod_record`'s default to env-aware and add `warn_on_inert_scoped_grant` + `warn_on_cross_controller_derivation` with the same default.
- **Requirements:** R1, R6 (partial — attr docs).
- **Dependencies:** none.
- **Files:** `lib/current_scope/configuration.rb`, `test/configuration_test.rb`.
- **Approach:** add `attr_accessor :warn_on_inert_scoped_grant` and `attr_accessor :warn_on_cross_controller_derivation`, each documented in the existing doc-comment style. Add a private `diagnostics_default_on?` returning `defined?(Rails) && Rails.respond_to?(:env) && Rails.env.local?` (mirror the existing private `production?` guard so a bare-Ruby `Configuration.new` without Rails is safe → `false`). In `initialize`, set all three flags to `diagnostics_default_on?`. Update the `warn_on_nil_sod_record` doc comment to state the new env-aware default and that it is log-only.
- **Patterns to follow:** the existing `attr_accessor` + `initialize` defaults + `production?` private guard already in `configuration.rb`.
- **Test scenarios:**
  - Under `Rails.env.test?` (the suite's env), all three flags default to `true`.
  - Stub `Rails.env` to `production` (or the existing test's env-override helper) → all three default to `false`.
  - With `Rails` undefined / not responding to `env`, `Configuration.new` raises nothing and the flags are `false` (bare-Ruby safety).
  - Each flag is assignable and reads back (host override wins over the default).
- **Verification:** config test green; defaults confirmed per-env; RuboCop omakase clean.

### U2. Guard: inert-scoped-grant nudge on the denial path

> ## ⚠️ PRE-FLIGHT (2026-07-15): this unit's premise was fixed out of existence by PR #49. Do not implement the sketch below literally.
>
> Probed against the tree as it is now, not reasoned about:
>
> | scenario | this plan assumes | actual |
> |---|---|---|
> | declared nil + scoped role **ticking** the key | `403 :no_grant` (so the nudge has something to fire on) | **`allowed=true`** |
> | **NO_RECORD** (no hook declared) | *didn't exist when this was written* | **`false, :no_grant`** |
> | declared nil + scoped **full_access** grant | — | `false, :no_grant` |
>
> **What happened.** PR #49 added the record-less scoped branch: a *declared* `nil` is the
> host stating "there is no record here", and a scoped role that ticks the key now opens the
> gate. That is this unit's headline "Fires" scenario — it is a **200 now, not a 403**. The
> same PR introduced `Guard::NO_RECORD` for "no hook declared", which is a *different value
> from nil* and is the case that actually still denies.
>
> **So the sketch's guard — `reason == :no_grant && record.nil?` — is wrong twice over:**
> it can never fire for the case it was written for (that case now allows), and it
> explicitly **excludes** `NO_RECORD`, the one case that is genuinely inert. What it would
> still catch is a declared nil + a scoped *full_access* grant — the deliberate,
> documented asymmetry (CONCEPTS.md, "Flagged ambiguities"), i.e. pure noise.
>
> Implemented literally, this diagnostic would be **0% true positives and 100% false
> positives**, and would fire on every collection request by a scoped-full_access subject
> while staying silent for the missing hook it exists to catch.
>
> **Corrected target.** The real inert case is `NO_RECORD` — a controller with member
> actions that never declared `current_scope_record` (the dummy's `HooklessMemberController`
> is precisely this shape, and its comment already says the gate "fails CLOSED there"). The
> nudge fires there and names the missing hook.
>
> **R5's `roles_granting` reuse survives check 2, and here is why it is safe HERE** — the
> question this nudge asks is the counterfactual *"had the hook returned the record, would
> this have been allowed?"*, which is exactly `scoped_grant?`'s question, and `scoped_grant?`
> **binds to a record**. That binding is the property that makes `roles_granting`'s
> full_access union safe, and the counterfactual preserves it. (Contrast plan 001 KTD-4,
> where the same reuse was proposed for a branch that bound to **no** record — that one
> turned one scoped grant into app-wide access. Same helper, opposite verdict, because the
> binding differs.)

- **Goal:** log a dev/test nudge when a `:no_grant` deny with a nil record coincides with the subject holding a matching scoped grant — the mirror of `nudge_on_nil_sod_record`, but on the deny side.
- **Requirements:** R2, R4, R5, and KTD-2/KTD-4.
- **Dependencies:** U1.
- **Files:** `lib/current_scope/guard.rb`, `lib/current_scope/resolver.rb` (new `scoped_grant_exists?` helper), `test/integration/guard_inert_scoped_grant_test.rb` (new; integration-style through `test/dummy`, add a controller/route where the record hook returns nil for one action).
- **Approach:** in `current_scope_check!`, on the denied branch, call the nudge **before** raising:
  - directional shape —
    ```ruby
    unless allowed
      nudge_on_inert_scoped_grant(permission, record, reason)
      raise CurrentScope::AccessDenied.new(permission, reason: reason)
    end
    ```
  - `nudge_on_inert_scoped_grant(permission, record, reason)` returns early unless `config.warn_on_inert_scoped_grant`, then unless `reason == :no_grant && record.nil?`, then unless `CurrentScope.resolver.scoped_grant_exists?(subject: CurrentScope::Current.user, permission: permission)`; otherwise `Rails.logger&.warn` a message that names the permission and points at the `action → model` mapping (the record hook returned nil), **hedged for the member-vs-collection ambiguity exactly like `nudge_on_nil_sod_record`** — close with wording of the form "if this is a member action, `current_scope_record` must return the record; if it's a collection action, this is expected", because a scoped role's permission set can legitimately list a *collection-action* key (e.g. `legacy#index`) that is inert by design, not by a forgotten mapping (see KTD-4 residual). Mirror the wording/structure of `nudge_on_nil_sod_record`.
  - add `Resolver#scoped_grant_exists?(subject:, permission:)` (public, next to `scope_for`): `return false if subject.nil?; ScopedRoleAssignment.where(subject: subject, role_id: roles_granting(permission)).exists?`. Read-only, no `resource:` filter (that is exactly the point — the grant exists but couldn't apply because the record was nil).
- **Execution note:** security-adjacent gate seam — write the failing tests first and watch them go red. The load-bearing guarantee is "**never** fires on advisory `allowed_to?`/`scope_for`, and the deny still raises unchanged."
- **Patterns to follow:** the existing `nudge_on_nil_sod_record` (same early-return ladder, same `Rails.logger&.warn`); `scope_for` / `scoped_grant?` for the query shape and `roles_granting` reuse.
- **Test scenarios:**
  - **Fires:** subject holds a scoped grant for `legacy#assign` on a record; controller's `current_scope_record` returns nil for `assign`; POST → still 403 `:no_grant`, and exactly one `[CurrentScope]` inert-scoped-grant warning is logged (assert on captured log). Input: mapped-but-forgotten action → expected: 403 unchanged + one nudge.
  - **No grant at all:** subject holds no scoped grant → 403 `:no_grant`, **no** nudge (this is a genuine deny, not a mis-map).
  - **Record present:** hook returns the record, grant applies → 200, no nudge (nothing inert).
  - **Advisory path:** `allowed_to?(:assign, record)` in a view for the same denied subject logs **zero** nudges (the nudge lives in Guard, not `Permissions`).
  - **Flag off:** `warn_on_inert_scoped_grant = false` → 403 unchanged, no nudge, and `scoped_grant_exists?` is never called (early return).
  - **Non-nil-but-other-deny:** reason `:sod_veto` → no inert-grant nudge (guarded on `:no_grant` + nil record).
  - **Collection-action false positive (hedged, accepted noise):** subject holds a scoped grant whose role's permission set lists a collection-action key (`legacy#index`); visiting `index` denies `:no_grant` with a nil record and `scoped_grant_exists?` true → the nudge *does* fire, but its message hedges ("if it's a collection action, this is expected"). Assert on the captured log that the hedge wording is present, so a future edit can't silently turn it back into a false "your mapping is wrong" assertion. This mirrors `nudge_on_nil_sod_record`'s own accepted residual.
  - **`scoped_grant_exists?` unit:** nil subject → false; subject with a full-access org role but no scoped grant → false (this helper is scoped-grants only); subject with a matching scoped grant on any record → true.
- **Verification:** new integration test green; existing guard/resolver suites unchanged and passing; the deny outcome and its `:no_grant` reason are provably identical with the flag on and off; RuboCop clean.

### U3. `permission_key`: cross-controller key-derivation divergence nudge

- **Goal:** warn (dev/test) when short-form derivation produces a key that diverges from the gate the current controller enforces, without changing the derived key.
- **Requirements:** R3, R4, and KTD-3.
- **Dependencies:** U1.
- **Files:** `lib/current_scope.rb` (the `permission_key` method + a private class-method helper), `test/permission_key_test.rb` (new or extend the existing derivation test if present).
- **Approach:** in `permission_key`, inside the `record.respond_to?(:model_name)` branch, after the `controller_path&.split("/")&.last == route_key` early return (the agreeing case), insert a call to a private class-method nudge **before** `return "#{route_key}##{action}"`:
  - directional shape —
    ```ruby
    return "#{controller_path}##{action}" if controller_path&.split("/")&.last == route_key
    warn_on_cross_controller_derivation(action, route_key, controller_path)
    return "#{route_key}##{action}"
    ```
  - `warn_on_cross_controller_derivation(action, route_key, controller_path)` returns early unless `config.warn_on_cross_controller_derivation`, unless `controller_path` present, and unless `catalog.include?("#{controller_path}##{action}")` (KTD-3 — the current controller genuinely gates this action; skips legitimate cross-resource checks). Then `Rails.logger&.warn` naming both keys: derived `"{route_key}#{action}"` vs the page's gate `"{controller_path}#{action}"`, and advising the explicit full key. Catalog lookup is a `Set` membership test — cheap even on the hot view path; the flag short-circuits in prod.
- **Execution note:** `permission_key` runs on every `allowed_to?`/`scope_for` in views — the test must prove the nudge does **not** fire on the common legitimate cross-resource case, which is the whole risk of this unit.
- **Patterns to follow:** the existing branch structure in `permission_key`; `CurrentScope.catalog.include?` as used in `Guard#current_scope_check!`.
- **Test scenarios:**
  - **Fires (foot-gun):** `controller_path = "dashboard"`, record is a `Report` (route_key `reports`), `catalog` includes `dashboard#show` → derived key is still `reports#show` (unchanged), and one nudge naming both `reports#show` and `dashboard#show` is logged. Input: `permission_key(:show, record: report, controller_path: "dashboard")` → expected: returns `"reports#show"` + one nudge.
  - **Silent (legitimate cross-resource):** `controller_path = "projects"`, record a `Report`, `catalog` does **not** include `projects#show` → returns `reports#show`, **no** nudge.
  - **Silent (agreeing):** `controller_path = "admin/reports"`, record a `Report` → early-returns `admin/reports#show`, nudge helper never reached.
  - **Silent (explicit full key):** `permission_key("dashboard#show")` → returns as-is, no derivation, no nudge.
  - **Silent (no controller_path, pure cross-resource from a component):** `controller_path` nil → returns `reports#show`, no nudge (can't have diverged from a gate that isn't there).
  - **Flag off:** returns identical keys with zero nudges; `catalog.include?` not consulted.
- **Verification:** new/extended derivation test green; the derived-key values are provably identical with the flag on and off; the legitimate cross-resource case is proven silent; RuboCop clean.

### U4. Documentation, initializer template, CHANGELOG/STATUS

- **Goal:** close the discoverability gap the issue is fundamentally about — make all three diagnostics visible where a host actually looks.
- **Requirements:** R6 (and the discoverability mandate).
- **Dependencies:** U1–U3.
- **Files:** `lib/generators/current_scope/install/templates/initializer.rb`, `README.md`, `CHANGELOG.md`, `STATUS.md` (and `docs/ROADMAP.md` if it tracks A5-style items).
- **Approach:** in the initializer template, replace the single commented `warn_on_nil_sod_record = false` block with a short "Development diagnostics" section documenting all three flags, stating the env-aware default (on in dev/test, off in prod) and that they are **log-only**. In `README.md`, add a compact "Dev-mode diagnostics" subsection (near "Record-level decisions" and the "Residual foot-gun" callout) that names the three nudges and when each fires; update the existing "Residual foot-gun" callout to mention that `warn_on_cross_controller_derivation` now detects it. In `CHANGELOG.md`, note the one visible behavior change (KTD-5): `warn_on_nil_sod_record` now defaults on in dev/test. Mark the item done in `STATUS.md`.
- **Test expectation: none — documentation/template only** (the initializer template is exercised by the existing generator test if one asserts on its content; no new behavior).
- **Verification:** README renders; the initializer section is self-contained and lists all three flags with the env default; CHANGELOG names the default flip; STATUS updated.

---

## Scope Boundaries

**In scope:** the env-aware config default + two new flags (U1); the inert-scoped-grant Guard nudge + the `scoped_grant_exists?` read helper (U2); the key-derivation-divergence nudge in `permission_key` (U3); docs/template/CHANGELOG (U4). Engine only. Every change is log-only.

**Deferred to Follow-Up Work:**
- The `current_scope_record_for "action", -> { … }` per-action record-declaration macro floated in issue finding #2. That is a genuine API addition (ergonomics for god/legacy controllers), not a diagnostic — it deserves its own issue/plan. This plan gives the *nudge* that makes the missing mapping loud; the macro that makes the mapping easier is separate.
- A `config.diagnostics` umbrella switch (see Open Questions).
- Raising instead of warning on the nil-SoD-record case in development (issue floats "or raise in dev"). Rejected here: a raise would change an *outcome* (200 → 500), violating R4's log-only guarantee, and the SoD skip on a genuine collection action is legitimate. Kept as a warn.

**Explicit non-goals (preserve deliberate design):**
- The single `current_scope_record` hook per controller stays — the route-derived catalog and per-controller record hook are deliberate. We diagnose the mis-map, we don't redesign the hook.
- SoD stays opt-in (`sod_actions` empty by default); no diagnostic turns it on.
- No production behavior change of any kind; no new audit rows, headers, or exceptions.

---

## Open Questions

- **Umbrella vs named flags.** Adopted three named flags (KTD-1) for discoverability. If the maintainer prefers a single `config.diagnostics = true/false` master (with the three as fine-grained overrides), U1 absorbs it cheaply — but it weakens the "a named flag teaches the failure mode" benefit that is the issue's core motivation. Flagged, not assumed.
- **Nudge channel.** All three use `Rails.logger&.warn`, consistent with the existing nudge. Confirm a plain `warn` (vs `ActiveSupport::Deprecation`-style or `Rails.error`) is the intended channel; log is the lowest-astonishment choice and matches the precedent.
- **Divergence false-positive residual (KTD-3).** The catalog-membership gate leaves one rare false positive: a controller that both routes `#approve` and hosts a cross-resource `allowed_to?(:approve, other_model)` check. Acceptable dev-only noise, or worth a further signal? Assumed acceptable.

---

## Cross-issue coupling

- **Sibling to the denial-ergonomics cluster (#24 denial-behavior ↔ #23 engine-403 ↔ #39 denial-ergonomics).** This plan's inert-scoped-grant nudge (U2) fires on the *same* `:no_grant` deny those issues reshape. If #23/#39 change the 403 body or the `X-Current-Scope-Reason` surfacing, they should compose with U2 by leaving the `reason == :no_grant` signal intact — the nudge keys off the machine-readable reason, so as long as that reason survives, the diagnostic survives. Whichever lands second should confirm the `:no_grant` reason is still produced on the nil-record inert-grant path.
- **Builds directly on the shipped break-glass work (`docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`).** That plan established the "nudge lives at the Guard seam, resolver stays pure, reason rides the return tuple" pattern (`nudge_on_nil_sod_record`, `record_sod_bypass`). U2 and U3 are deliberate reuses of that exact pattern — no new architecture.
- **Adoption-guide (#26) / report-only (#37) overlap.** The initializer/README diagnostics section (U4) is a natural anchor for any adoption guide; if #26 lands a "getting started" doc, it should link the diagnostics section rather than re-document the flags.
