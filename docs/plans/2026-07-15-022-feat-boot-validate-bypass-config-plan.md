---
title: Boot-Validate sod_bypass_permission Not In sod_actions - Plan
type: feat
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/40
---

# Boot-Validate `sod_bypass_permission` Not In `sod_actions`

## Goal Capsule

- **Objective:** move the existing "the bypass permission must not be an SoD action — it would recurse" check from **decision time** (where it fires only behind three live preconditions, so the forbidden misconfig deploys clean and first surfaces as a production 500 on a real break-glass attempt) to **boot time**, so the unsafe deploy fails loudly and immediately — exactly as the impersonation prod-gate already does. Keep the decision-time raise as defense in depth.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `docs/ROADMAP.md`, the shipped break-glass plan `docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`). The resolver decision order (SoD veto → full_access → org role → scoped role → deny), the **fail-closed** posture, **one-org-role-per-subject**, resolver **PURITY** (no writes, no per-decision state, thread-shared, memoizable), and ambient `CurrentAttributes` context are **immutable**. This change adds a boot-time raise for an *already-forbidden* configuration; it changes **no** decision path and **no** behavior for a correctly-configured host.
- **Stop conditions — surface, do not guess, if:** (a) the boot check and the decision-time check would use *different* normalization of the permission→action mapping (they must share one predicate, or a host can pass boot and still recurse — see KTD-2); (b) validating at boot would require the resolver to hold state or perform a write (it must not — validation lives on `Configuration`/`Engine`, never in `decide`); (c) the fix would make a *correctly*-configured host raise at boot (a false positive in an authorization library's boot path is itself a broken deploy); (d) removing the decision-time raise would leave any runtime-mutated-config path (the test suite mutates config live) able to reach a `SystemStackError`.

---

## Product Contract

> **Product Contract preservation:** enhancement on shipped v0.2 behavior, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded entirely in the filed issue and the shipped break-glass plan.

### Summary

The engine already **forbids** listing the break-glass bypass permission in `config.sod_actions` — that pairing would recurse into a `SystemStackError` (the bypass check calls `CurrentScope.allowed?(sod_bypass_permission, …)`, which would re-enter the SoD step). Today that guard lives only inside `Resolver#sod_bypassed?` (`lib/current_scope/resolver.rb:148-153`) and therefore only runs when **all three** break-glass preconditions align at decision time: `allow_sod_bypass` on, the record's `current_scope_sod_bypassed?` hook true, and a live initiator-vs-subject SoD conflict. So the misconfiguration boots clean, passes the config-off path, passes the no-conflict path, and only 500s at the **first real self-approval bypass in production**. The message is excellent; the timing is the gap. This plan validates the invariant **once at boot**, after the host's initializer has finalized config, and raises `ConfigurationError` there — while keeping the decision-time raise as a backstop for runtime-mutated config.

### Problem Frame

The gem's stated philosophy (issue, and the `allow_mutations_while_impersonating` prod-gate at `configuration.rb:161-173`) is: **an unsafe deploy fails loudly at boot, not silently at runtime.** The bypass-in-`sod_actions` check violates that philosophy — it is a wiring mistake that an authorization library must catch at wire-up time, not turn into a latent production 500 that appears precisely when an operator is trying to break glass under pressure. `README.md:317` already promises "the engine raises if it does" without pinning the timing; this closes the gap between the promise and the behavior.

### Requirements

- **R1.** At boot, after the host initializer has run, the engine raises `CurrentScope::ConfigurationError` if the action derived from `config.sod_bypass_permission` is present in `config.sod_actions`. A correctly-configured host boots unchanged. A host whose break-glass is OFF (`allow_sod_bypass = false`) but whose `sod_bypass_permission` *inertly* collides with an `sod_action` — booting and running fine today because the decision-time guard is gated on `allow_sod_bypass` and never fires — will **newly fail boot on upgrade**. This is intentional (see KTD-4): that pairing is a latent bug that recurses the instant `allow_sod_bypass` flips on, so it fails loud immediately rather than lying in wait.
- **R2.** The boot check and the decision-time check derive the "action name" from `sod_bypass_permission` **identically** (both must strip a namespaced `"controller#action"` to its bare action before comparing), so no configuration can pass one gate and fail the other.
- **R3.** The decision-time raise in `Resolver#sod_bypassed?` is **retained** as defense in depth — config can be mutated after boot (the test suite does exactly this), and the resolver guard must still prevent a `SystemStackError` on that path.
- **R4.** Boot validation performs **no writes and holds no state**; it lives on `Configuration`/`Engine`, never inside the resolver's `decide` path. Resolver purity is untouched.
- **R5.** The boot raise message is actionable — it names `config.sod_bypass_permission`, the offending action, `config.sod_actions`, and the remedy (remove the action from `sod_actions`), consistent with the existing decision-time message.
- **R6.** `README.md` (and `CHANGELOG.md`) state the timing explicitly: this invariant is enforced **at boot**.

---

## Key Technical Decisions

- **KTD-1 — Validate in `Engine.config.after_initialize`, not in a config writer.** The invariant spans **two independently-assigned** attributes (`sod_actions` and `sod_bypass_permission`), each a plain `attr_accessor`. A guarded writer on either one (the pattern `allow_mutations_while_impersonating=` uses) is **order-dependent and defeatable**: set the bypass permission first and `sod_actions` later, and a writer on the bypass permission never sees the conflict. `after_initialize` runs **once, after** the host's `config/initializers/current_scope.rb` has fully populated config, so both fields are final and the cross-field invariant can be checked correctly. This is the honest seam for a multi-field invariant; the impersonation prod-gate's single-value writer is not a fit here. (Do **not** also run it in `config.to_prepare` — config values are set once at boot in an initializer and don't change on code reload; adding it to the per-reload hook buys nothing and couples validation to reloading.)
- **KTD-2 — One shared predicate; the two checks must not drift.** `resolver.rb:147` currently inlines `config.sod_bypass_permission.to_s.split("#").last` and compares to `sod_actions`. If the boot check re-implements that normalization separately, a future change to one (e.g. handling a different key format) silently desyncs them and re-opens the exact hole this issue closes. Extract the mapping and the conflict test **onto `Configuration`** as the single source of truth (e.g. `sod_bypass_permission_conflicts_with_sod_actions?`), and have **both** the boot `validate!` and the resolver's defense-in-depth guard call it. Root-cause fix at the shared seam, not two parallel string-splits.
- **KTD-3 — Keep the decision-time raise (defense in depth).** Boot is the primary gate, but config is mutable at runtime and the test suite (`test/sod_bypass_test.rb:111`) sets `sod_bypass_permission = "approve"` live and asserts the resolver raises. Removing the resolver guard would (a) break that contract and (b) reopen a `SystemStackError` path for any host that reassigns config after boot. The resolver keeps its guard — it just delegates the *conflict test* to the shared predicate (KTD-2). A `ConfigurationError` raised from the resolver is a wiring failure, **not** a decision, and does not violate purity (it performs no write and holds no state — identical in kind to the existing `INITIATOR_METHOD` raise at `resolver.rb:113`).
- **KTD-4 — No production env-gate; raise in every environment.** Unlike `allow_mutations_while_impersonating` (prod-gated behind an env opt-in because impersonated writes are legitimately wanted in some prod deploys), a bypass-in-`sod_actions` config is **never** valid anywhere — it can only ever recurse. So it raises unconditionally in development, test, and production alike — **and unconditionally regardless of `allow_sod_bypass`.** A host with break-glass OFF but a colliding `sod_bypass_permission`/`sod_actions` pairing boots and runs fine today (the decision-time guard is gated on `allow_sod_bypass` at `resolver.rb:140`, so it never fires); on upgrade its previously-green boot turns red. That backward-incompatible surprise is intended, and the apply step and maintainer should expect it: gating the boot check on `allow_sod_bypass` to spare that host would re-introduce a precondition-hidden check — the exact anti-pattern this issue closes — and would leave the latent bug armed to fire the instant the switch flips on. Fail loud at boot, always. This also gives developers the fastest possible feedback (boot fails on their machine, not in prod).

---

## Implementation Units

### U1. Shared conflict predicate on `Configuration` + `validate!`

- **Goal:** put the "does the bypass permission collide with an SoD action?" logic in exactly one place, and add the `validate!` entry point that raises on it.
- **Requirements:** R1, R2, R4, R5.
- **Dependencies:** none.
- **Files:** `lib/current_scope/configuration.rb`, `test/configuration_test.rb`.
- **Approach:** add two methods to `Configuration`:
  - a small predicate, directionally `sod_bypass_permission_conflicts_with_sod_actions?`, that computes `sod_bypass_permission.to_s.split("#").last` and returns whether `sod_actions.include?` it — the *same* normalization the resolver inlines today.
  - `validate!` which, when that predicate is true, raises `ConfigurationError` with the boot-framed, actionable message (names the config keys and the remedy; mirror the existing decision-time wording so the two are recognizably the same rule). Shape `validate!` as the extensible seam future config invariants append to, but scope it to this one check now (no validation framework — YAGNI).
- **Patterns to follow:** the `ConfigurationError` raise style and message tone already in `configuration.rb:161-173` (impersonation prod-gate) and `resolver.rb:148-153` (the existing decision-time message).
- **Test scenarios (input → expected):**
  - `sod_bypass_permission = "approve"`, `sod_actions = %w[approve]` → `validate!` raises `ConfigurationError`, message matches `/must not be an SoD action/` and mentions `sod_actions`.
  - Namespaced form `sod_bypass_permission = "reports#approve"`, `sod_actions = %w[approve]` → still raises (R2 normalization proven).
  - Default config (`sod_bypass_permission = "bypass_sod"`, `sod_actions = []`) → `validate!` returns without raising.
  - `sod_bypass_permission = "bypass_sod"`, `sod_actions = %w[approve]` (the common, correct break-glass setup) → no raise.
  - Predicate is a pure read: calling `validate!` performs no DB write and mutates no config (assert config fields unchanged).
- **Verification:** configuration test green; the predicate and `validate!` behave as enumerated; RuboCop omakase clean.
- **Execution note:** security-relevant config seam — write the raising/non-raising tests first and watch them go red before adding the methods.

### U2. Wire `validate!` into engine boot; resolver delegates to the shared predicate

- **Goal:** run `validate!` once at boot, and replace the resolver's inlined string-split with a call to the shared predicate so the two checks can never drift.
- **Requirements:** R1, R2, R3, R4.
- **Dependencies:** U1.
- **Files:** `lib/current_scope/engine.rb`, `lib/current_scope/resolver.rb`, `test/configuration_test.rb` (boot-seam smoke), `test/sod_bypass_test.rb` (existing decision-time raise stays green).
- **Approach:**
  - In `engine.rb`, add `config.after_initialize { CurrentScope.config.validate! }` (a new block alongside the existing `config.to_prepare`). This fires after the host initializer, once, on the finalized config.
  - In `resolver.rb#sod_bypassed?`, replace the inlined `bypass_action = …split("#").last` + `sod_actions.include?` check (lines ~147-153) with `if CurrentScope.config.sod_bypass_permission_conflicts_with_sod_actions?` → raise. The resolver keeps its own raise (KTD-3) but sources the boolean from `Configuration` (KTD-2). Preserve the existing message or delegate to a shared message constant — either is fine as long as the *test* for the conflict is the shared predicate.
- **Patterns to follow:** the existing `config.to_prepare do … end` block in `engine.rb`; the existing raise in `sod_bypassed?`.
- **Test scenarios (input → expected):**
  - **Boot seam fires:** with a deliberately-conflicting config, invoking `CurrentScope.config.validate!` (the exact call the initializer makes) raises — proving the wired seam would fail the boot. (Full end-to-end reboot of the already-booted dummy app is impractical in-process; the seam is a one-liner delegating to U1's fully-tested `validate!`, so this asserts the wiring, U1 owns the logic.)
  - **Valid dummy config passes:** `CurrentScope.config.validate!` on the dummy app's real (valid) config returns without raising — proves no false-positive at boot (Stop-condition c).
  - **Decision-time backstop intact:** the existing `test/sod_bypass_test.rb:111` ("a bypass permission that is itself an SoD action is refused loudly") still passes unchanged — runtime-mutated config still raises at `decide` time (R3).
  - **No drift:** the resolver now raises via the shared predicate — a unit test setting the conflicting config and calling the resolver still matches `/must not be an SoD action/`.
- **Verification:** engine boots on valid config; the seam and resolver both raise on the conflict through one predicate; the full existing suite (esp. `sod_bypass_test`) is green; RuboCop clean.
- **Execution note:** touch the resolver last and re-run `test/sod_bypass_test.rb` + `test/resolver_test.rb` to prove the delegation changed no decision behavior.

### U3. Documentation

- **Goal:** pin the timing in the docs the promise lives in.
- **Requirements:** R6.
- **Dependencies:** U1, U2.
- **Files:** `README.md` (the break-glass subsection, near the current "the engine raises if it does" line ~317), `CHANGELOG.md`.
- **Approach:** amend the README sentence to state the invariant is enforced **at boot** (an unsafe pairing fails the deploy immediately), with the decision-time check noted as defense-in-depth. Add a `CHANGELOG.md` entry describing the boot-time validation.
- **Patterns to follow:** the "fails loudly at boot" framing already used for the impersonation prod-gate in the README and `configuration.rb`.
- **Test expectation:** none — documentation only.
- **Verification:** README renders; the timing claim now matches actual behavior; CHANGELOG entry present.

---

## Scope Boundaries

**In scope:** the shared conflict predicate + `validate!` on `Configuration`, the `after_initialize` boot wiring in `Engine`, the resolver's delegation to the shared predicate (retaining its raise), tests, and the doc timing fix. Engine only.

**Preserved deliberate design choices (unchanged):** resolver purity, fail-closed posture, opt-in SoD, route-derived permission catalog, the break-glass three-way AND and its `:sod_bypassed` audit. This plan adds a boot raise for an already-forbidden config and nothing else.

### Deferred to Follow-Up Work

- A **general** `Configuration#validate!` suite for *other* boot-checkable invariants (e.g. `sod_bypass_permission` blank, `sod_identity` not in `%i[either subject]`, `audit` not a valid tri-state). The seam is shaped to accept them; adding them is out of scope here (YAGNI — only the recursion invariant is the filed issue). If pursued, each is one more guard clause in `validate!`.
- Surfacing config-validation failures with a boot-time diagnostic that lists *all* problems at once rather than raising on the first — only worth it once there are several invariants.

**Non-goals:** no change to the decision order, the audit ledger, the header contract, or any correctly-configured host's boot or runtime behavior. No production env-gate (KTD-4).

---

## Open Questions

- **Message unification vs. two messages.** U2 can either keep the resolver's existing message verbatim (only sourcing the *boolean* from the shared predicate) or route both raises through one shared message string. The plan assumes the former (minimal churn; the decision-time and boot messages differ slightly in framing — "at boot" vs "at decision"). Confirm if a single canonical message is preferred.
- **`after_initialize` vs. a named `initializer`.** `config.after_initialize` runs after *all* app initializers; a named `initializer "current_scope.validate"` with `after:`/`before:` ordering is also available. `after_initialize` is the simplest correct choice (config is guaranteed final). Flag if the maintainer wants explicit ordering relative to other engine initializers.

---

## Cross-issue coupling

- **Companion to the shipped break-glass work** (`docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`, and the #20/#21 permission-keys-drop ↔ `bypass_sod`-ungrantable cluster). This issue hardens the *configuration-safety* half of that feature: the break-glass plan introduced the recursion invariant and its decision-time guard (KTD-5 there); this plan promotes that same invariant to boot time. The two compose cleanly — no overlap in files beyond the resolver's `sod_bypassed?`, which this plan only refactors (delegates the conflict test) without changing its runtime semantics. If both land near each other, sequence this **after** the break-glass plan (it depends on `sod_bypass_permission`, `allow_sod_bypass`, and the resolver guard already existing — all confirmed present in source).
