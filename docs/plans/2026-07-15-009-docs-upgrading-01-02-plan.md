---
title: UPGRADING.md — 0.1→0.2 SoD-default flip and Rails floor - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/27
---

# UPGRADING.md — 0.1→0.2 SoD-default flip and Rails floor - Plan

## Goal Capsule

- **Objective:** give 0.1 adopters a single, findable upgrade guide (`UPGRADING.md`) whose lead item is the one change that can silently disable a security control: `config.sod_actions` flipped from `%w[approve]` (0.1) to `[]` (0.2), so an app that relied on the 0.1 default loses its separation-of-duties veto on upgrade with **no error and no warning** — self-approvals simply start succeeding. Cover the Rails `>= 8.1` floor, and wire a link from the CHANGELOG's terse `Changed` line to the guide. Then, in a follow-on 0.2.x patch, add a **one-time, fail-open, log-only boot warning** that fires when a host has SoD models (`current_scope_initiator`-bearing) but `sod_actions` is empty — the strongest available signal that someone upgraded straight past the flip.
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `CHANGELOG.md`, `docs/ROADMAP.md`, `resources/DESIGN.md` if present). The engine invariants are **immutable and NOT touched by this issue**: resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver PURITY (no writes / no per-decision state), and the ambient `CurrentAttributes` context. U1/U2 are pure documentation. U3 is a **boot-time, log-only** advisory that emits from an engine/railtie seam — never from the resolver decision path — and can only ever print a warning, never change a decision or raise.
- **Deliberate design being preserved:** the SoD-opt-in default itself is **correct and stays** (`configuration.rb:17-20`, `CHANGELOG` 0.2.0 "Separation of duties is opt-in"). This issue does not re-litigate the default — it makes the *transition* loud instead of silent. Do not "fix" the flip by reverting the default; that would re-break every RBAC-only host the flip was made for.
- **Stop conditions — surface rather than guess if:**
  - (a) the boot warning (U3) cannot detect SoD models without eager-load (dev with `eager_load=false` genuinely can't enumerate host models) — accept the miss and document it, do **not** force eager-load or hook the hot decision path to compensate;
  - (b) making the warning "reliable" would require adding per-decision state to the resolver or a check in `decide`/`allow?` (its purity is non-negotiable — emit from boot or the Guard seam like `warn_on_nil_sod_record`, never the resolver);
  - (c) the warning could ever raise or block boot on a legitimately-RBAC-only host (it must be advisory-only, warn-once, and silenceable).

---

## Product Contract

> **Product Contract preservation:** documentation issue (with a small paired code advisory), no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Grounded in the filed finding (`issue #27`) and re-verified 2026-07-15 against `lib/current_scope/configuration.rb:17-20,135`, `CHANGELOG.md:26-30`, `README.md:241-287`, `lib/current_scope/engine.rb`, and `lib/current_scope/guard.rb:86` (the `warn_on_nil_sod_record` precedent).

### Summary

Ship the upgrade guide the 0.2.0 release skipped. The version bump changed one default that matters for security — SoD went from on-for-`approve` to fully off — and today that change lives in a single CHANGELOG line (`CHANGELOG.md:26`). Upgraders who used SoD on 0.1 defaults get no signal that their four-eyes control is gone. Add `UPGRADING.md` with a 0.1→0.2 checklist led (in bold) by the `sod_actions` flip, cover the Rails 8.1 floor, and link the CHANGELOG to it. Then add a log-only boot warning so the silent case becomes an audible one.

### Problem Frame

Three facts, all verified against source:

1. **The flip is real and silent.** 0.1 shipped `config.sod_actions` defaulting to `%w[approve]` (per the issue's 0.1 evidence); 0.2 defaults it to `[]` (`configuration.rb:135`, documented `configuration.rb:17-20`). An app that never set `sod_actions` and relied on the default to gate `approve` loses the veto entirely on upgrade — the resolver's SoD step becomes a no-op (`README.md:274-278`), self-approvals succeed, nothing is logged, nothing raises. This is precisely the "silent fail-open" the gem crusades against.
2. **No upgrade guide exists.** The repo root has `CHANGELOG.md`, `README.md`, `STATUS.md`, `PRODUCT.md` — no `UPGRADING.md`. The only record of the flip is `CHANGELOG.md:26` ("**Separation of duties is opt-in**: `config.sod_actions` now defaults to `[]`."), which states the new default but not the *migration action* for someone who relied on the old one.
3. **The Rails floor also moved.** 0.2 declares `>= 8.1` (`CHANGELOG.md:27-28`, the management UI uses `params.expect` array semantics). A 0.1 host on Rails 8.0 must bump Rails to take 0.2 — a second, unrelated upgrade gotcha with no guide.

The remediation is documentation-first (U1, U2) plus one loud-but-safe runtime signal (U3) that turns the specific dangerous case — "you have SoD models but SoD is now off" — from silent into a boot log line.

### Requirements

- **R1.** A new `UPGRADING.md` at the repo root, opening with a plain-language What/Why/How, then a **"0.1 → 0.2"** section whose **first and boldest** item is the `sod_actions` flip, stating the exact remediation: *if you relied on SoD on 0.1 defaults, re-add `config.sod_actions = %w[approve]` (plus any other gated actions) to your initializer* — with a one-line "how to tell if this affects you" (you have models defining `current_scope_initiator` and never set `sod_actions`).
- **R2.** The same 0.1→0.2 section documents the **Rails `>= 8.1` floor** (why: `params.expect` array semantics in the management UI) and the remediation (bump Rails before upgrading the gem).
- **R3.** The section is a **checklist** an upgrader can execute top-to-bottom, and links back to the README "Separation of duties (opt-in)" section (`README.md:241`) for the full model, not a duplicate of it.
- **R4.** `CHANGELOG.md` links to `UPGRADING.md` from the 0.2.0 entry — specifically an inline pointer on the SoD `Changed` line (`CHANGELOG.md:26`) and a "see UPGRADING.md" note near the top of the 0.2.0 block — so the terse changelog and the actionable guide are connected in both directions.
- **R5.** (0.2.x patch) A **one-time, log-only** boot warning fires when `config.sod_actions` is empty **and** at least one eager-loaded host model defines `current_scope_initiator` — telling the operator SoD is off despite the presence of SoD-shaped models, and pointing at `UPGRADING.md`. It is advisory-only: it never raises, never changes a decision, warns at most once per boot, and is emitted from a boot/engine seam, not the resolver.
- **R6.** The boot warning is **silenceable** for a host that legitimately keeps SoD off while defining the hook for other reasons (e.g. a model that returns `nil` to exempt itself) — no config churn for the common case, one opt-out for the false-positive case.

---

## Key Technical Decisions

- **KTD-1 — `UPGRADING.md` at the repo root, not under `docs/`.** `UPGRADING.md` is a near-universal convention (peers to `CHANGELOG.md`/`README.md`); adopters and tooling look for it at the root. `docs/` holds design/roadmap/plans, not adopter-facing runbooks. Ponytail: one new root file, no new tree. The 0.1→0.2 section is the whole file's content today; future major bumps append `## 0.2 → 0.3` sections above it (newest-first) — no scaffolding needed now.
- **KTD-2 — Document the flip, do NOT revert the default.** The opt-in default is a deliberate, changelog-announced design choice made *for* the RBAC-only majority. The bug is the silent transition, not the destination. The fix is a loud transition (guide + boot warning), never a re-flip — reverting would silently re-enable four-eyes for every host that upgraded cleanly, i.e. the mirror-image fail. This is the load-bearing boundary.
- **KTD-3 — The boot warning emits from the engine/railtie seam, never the resolver (purity guardrail).** The resolver (`resolver.rb`) is pure/memoized/thread-shared; adding a "have I warned yet" flag or a hook-scan to `decide`/`allow?` would break that contract and put a diagnostic in the hot path. Precedent already exists: `warn_on_nil_sod_record` is "Emitted from the Guard seam (not the shared resolver)" (`configuration.rb:113-118`, `guard.rb:86`). U3 goes one better and runs **at boot**, so it costs nothing per-request. Use an engine `config.after_initialize` block guarded by the app's `eager_load` flag (so `ApplicationRecord.descendants` is actually populated).
- **KTD-4 — Design fork for detection, picked: eager-load-time descendant scan, prod-focused, fail-open on the miss.** Two options: **(a)** boot-time scan of `ApplicationRecord.descendants` for `current_scope_initiator` (via `method_defined?`/`private_method_defined?`, honoring inherited and mixed-in definitions to match the resolver's `respond_to?(…, true)` at `resolver.rb:112`) under `after_initialize` when `eager_load` is on; **(b)** lazy first-request warn from the Guard when an SoD-hook-bearing record is gated while `sod_actions` is empty. Pick **(a)**: it is where the silent-fail actually bites (production eager-loads, so the scan is complete there), it is zero per-request cost, and it can never touch a decision. Its known ceiling — dev/test with `eager_load=false` won't enumerate models, so the warning may not fire there — is acceptable (`ponytail:` the risk case is production, and Stop condition (a) says accept the miss rather than forcing eager-load). Option (b) is rejected: it re-introduces a per-decision concern near the resolver/Guard hot path for a diagnostic. Note (a) also has a benign false-positive: a model whose `current_scope_initiator` returns `nil` to *exempt* itself still counts as "SoD-shaped" — hence the silence knob (R6, KTD-5).
- **KTD-5 — Silence knob reuses config, not a new subsystem.** For the false-positive host, add one boolean the operator can set once. Default: warning **on** (the whole point is loudness for the dangerous default). Naming/placement is an Open Question — either a dedicated `config.warn_on_sod_disabled_with_initiators` (mirrors the existing `warn_on_*` family and initializer comment style) or reuse a broader "suppress advisory warnings" switch if one is later introduced. Plan assumes the dedicated `warn_on_*` boolean, default `true`, documented in the initializer template alongside `warn_on_nil_sod_record`.

---

## Implementation Units

### U1. `UPGRADING.md` — the 0.1→0.2 guide

- **Goal:** create `UPGRADING.md` at the repo root with a What/Why/How opener and an executable 0.1→0.2 checklist led, in bold, by the `sod_actions` flip, plus the Rails 8.1 floor.
- **Requirements:** R1, R2, R3.
- **Dependencies:** none.
- **Files:** `UPGRADING.md` (new).
- **Approach:** structure, directional:
  1. **Opener (What/Why/How, plain language).** What: 0.2 turned separation-of-duties off by default; if you used it on 0.1 defaults it's now silently disabled. Why it matters: self-approvals that were blocked will now succeed with no error. How to fix: re-add the config line below.
  2. **`## 0.1 → 0.2`** checklist. **Item 1 (bold, first): separation of duties is now opt-in.** State the flip (`%w[approve]` → `[]`), the exact remediation `config.sod_actions = %w[approve]` (list every action you gated, not just `approve`), and a "does this affect me?" test: *you have one or more models defining `current_scope_initiator` and you never set `config.sod_actions` explicitly.* Cross-link `README.md#separation-of-duties-opt-in` for the full model rather than restating it (R3). Mention the 0.2.x boot warning (U3) as the automated backstop.
  3. **Item 2: Rails floor is now `>= 8.1`.** Why (`params.expect` array semantics in the management UI, per `CHANGELOG.md:27-28`); remediation (bump Rails to ≥ 8.1 before bumping the gem).
  4. **Item 3 (brief pointers): other 0.2 additions are additive/opt-in** — audit ledger, impersonation, scoped-role picker — none change existing behavior unless configured; link the CHANGELOG 0.2.0 entry for the full list rather than duplicating it. Keep this short; the file's job is the *breaking/silent* changes, not a second changelog.
- **Patterns to follow:** the plain-language What/Why/How opener used across this project's tickets/PRs; the README's existing SoD prose voice (`README.md:241-287`) for accurate terminology (initiator hook, "loud not open", exempt-with-nil).
- **Test scenarios:** Test expectation: none — documentation only. Correctness is verified by grounding every claim against source (below).
- **Verification:** `UPGRADING.md` exists at repo root; the `sod_actions` remediation matches `configuration.rb:135` (new default `[]`) and the 0.1 default asserted in the issue (`%w[approve]`); the Rails floor claim matches `CHANGELOG.md:27-28`; the README cross-link anchor resolves; the "does this affect me?" test names the real hook (`current_scope_initiator`).

---

### U2. CHANGELOG cross-links to `UPGRADING.md`

- **Goal:** connect the terse 0.2.0 changelog entry to the actionable guide in both directions.
- **Requirements:** R4.
- **Dependencies:** U1 (the file must exist to link to).
- **Files:** `CHANGELOG.md`.
- **Approach:** two small edits inside the `## [0.2.0]` block: (a) append a pointer to the SoD `Changed` line (`CHANGELOG.md:26`), e.g. `… now defaults to []. **If you relied on the old default, see [UPGRADING.md](UPGRADING.md).**`; (b) add a one-line "Upgrading from 0.1? See [UPGRADING.md](UPGRADING.md)." note near the top of the 0.2.0 entry (just under the date header) so a reader scanning the release sees it before the section breakdown. Do not restructure the changelog or move existing entries.
- **Patterns to follow:** the existing Keep-a-Changelog formatting and reference-link style already in the file (`CHANGELOG.md:52-54`).
- **Test scenarios:** Test expectation: none — documentation only.
- **Verification:** both links point at `UPGRADING.md`; the changelog still parses as Keep-a-Changelog (headings/sections intact); no existing entry text lost.

---

### U3. One-time boot warning: SoD models present but `sod_actions` empty (0.2.x patch)

- **Goal:** at boot, when SoD is off but the host clearly has SoD-shaped models, emit exactly one log warning pointing at `UPGRADING.md` — advisory only, never a raise, never a decision change, silenceable.
- **Requirements:** R5, R6, and KTD-3/4/5.
- **Dependencies:** U1 (the warning references the guide). Independent of U2.
- **Files:** `lib/current_scope/engine.rb` (add the `after_initialize` advisory), `lib/current_scope/configuration.rb` (add the silence knob per KTD-5), `lib/generators/current_scope/install/templates/initializer.rb` (document the knob), `test/sod_disabled_warning_test.rb` (new).
- **Approach (directional):**
  - In `engine.rb`, add `config.after_initialize do |app| … end`. Guard the whole block on `app.config.eager_load` (else host models aren't enumerable — KTD-4, Stop condition (a)) **and** `CurrentScope.config.sod_actions.empty?` **and** the silence knob being on. Only then scan for SoD-shaped models: `ApplicationRecord.descendants.select { |m| m.method_defined?(:current_scope_initiator) || m.private_method_defined?(:current_scope_initiator) }`. Use `method_defined?`/`private_method_defined?` (which honor inheritance and mixed-in modules), **not** `instance_methods(false)` — this matches how the resolver actually resolves the hook (`record.respond_to?(:current_scope_initiator, true)`, `resolver.rb:112`), so a host that defines `current_scope_initiator` in a shared concern or a base class is still caught (exactly the upgraders the backstop is for). If any exist, `Rails.logger.warn` once with a message naming the finding and linking `UPGRADING.md`.
  - Warn-once: the `after_initialize` block runs once per boot, so a module-level guard is unnecessary in production; in a reloading dev environment `after_initialize` still fires once per process — good enough (no per-request state, KTD-3).
  - Silence knob: `config.warn_on_sod_disabled_with_initiators` (default `true`) in `configuration.rb` (`attr_accessor` + `initialize` default), documented in the initializer template next to `warn_on_nil_sod_record`.
  - Message content, directional: *"CurrentScope: config.sod_actions is empty (SoD off) but N model(s) define current_scope_initiator (…names…). If you upgraded from 0.1, separation of duties may be silently disabled — see UPGRADING.md. Set config.warn_on_sod_disabled_with_initiators = false to silence."*
- **Execution note:** behavior-adjacent (it reads config and model metadata at boot). Write the test first: assert the warning fires under the trigger condition and, critically, that it does **not** fire when `sod_actions` is non-empty, when no model defines the hook, or when the knob is off — and that it never raises. This is the guardrail that keeps a diagnostic from becoming a boot-breaker.
- **Patterns to follow:** `warn_on_nil_sod_record` end-to-end — the config `attr_accessor` + `initialize` default (`configuration.rb:119,147`), the `Rails.logger.warn` advisory emitted from a non-resolver seam (`guard.rb:86`), and the initializer-template comment block (`templates/initializer.rb:63-68`). Reuse that shape; do not invent a new warning subsystem.
- **Test scenarios (input → expected):**
  - **Trigger:** `eager_load` on, `sod_actions = []`, a test model defines `current_scope_initiator`, knob on → exactly one `Rails.logger.warn` naming the model and `UPGRADING.md`.
  - **SoD on:** `sod_actions = %w[approve]`, hook-bearing model present → **no** warning (the host configured SoD; nothing silent).
  - **No SoD models:** `sod_actions = []`, no model defines the hook → **no** warning (RBAC-only host, the majority — must stay quiet).
  - **Silenced:** trigger condition met but `warn_on_sod_disabled_with_initiators = false` → no warning (R6 false-positive escape hatch).
  - **eager_load off:** `sod_actions = []`, hook-bearing model exists but `eager_load=false` → no warning, no error (documented miss, KTD-4 — assert it does not raise while scanning an unpopulated `descendants`).
  - **Never raises:** even if a model's ancestry/metadata is odd, the block rescues nothing it shouldn't but must not blow up boot — assert the app boots green in every case above.
- **Verification:** new test green; the existing suite unchanged and passing; `bin/rubocop` clean; a scratch app with `sod_actions=[]` and an `current_scope_initiator` model logs the warning once at boot; the same app with `sod_actions=%w[approve]` boots silent.

---

## Scope Boundaries

**In scope:** one new root `UPGRADING.md` (U1), two CHANGELOG cross-link edits (U2), and one log-only boot advisory + its silence knob + initializer-doc line + test (U3). A `CHANGELOG.md` "Unreleased" note for U3 when it ships as the 0.2.x patch.

**Explicit non-goals — preserve deliberate design:**
- **No change to the `sod_actions` default.** `[]` (opt-in SoD) stays (KTD-2). This issue makes the transition loud, it does not undo it.
- **No change to the resolver, the decision order, the fail-closed posture, or resolver purity.** U3 is boot-time and log-only; it never touches `decide`/`allow?` (KTD-3, Stop conditions b).
- **No raise, no boot-block, no behavior change** from U3 — it is strictly advisory (a host that ignores it is exactly as functional as before).
- No auto-migration of a host initializer, no attempt to re-add `sod_actions` for the user, no forcing `eager_load`.

**Deferred to Follow-Up Work (tangential):**
- A general `docs/` (or root) adoption/onboarding guide that folds UPGRADING into a broader "first 30 minutes" narrative — companion territory to the adoption-guide issue (#26); link, don't duplicate.
- Extending the U3 pattern into a broader "config sanity check at boot" that also flags other silent-fail-open shapes (e.g. `audit=false` with an events table present). Out of scope here; note the seam is reusable.
- A dev-environment variant of the warning (lazy first-request) if the eager-load miss proves painful in practice — explicitly rejected for now (KTD-4).

---

## Open Questions

- **Silence-knob name (KTD-5).** `config.warn_on_sod_disabled_with_initiators` (assumed) mirrors the `warn_on_nil_sod_record` family and is self-describing, but it's verbose. Maintainer to confirm the name, or whether a single umbrella `config.warn_on_advisory_config` switch is preferred before U3 ships.
- **U3 release vehicle.** The issue frames the boot warning as a *0.2.x patch* backstop; U1/U2 can ship immediately as docs. Confirm U3 lands in the next patch (additive, default-on) rather than being held for 0.3 — the whole value is catching current upgraders, so sooner is better.
- **0.1 default provenance.** The plan takes the 0.1 `sod_actions` default as `%w[approve]` from the issue's verified repro. If the maintainer wants the guide to cite the exact 0.1 source line, confirm it against the `v0.1.0` tag before publishing (the working tree is 0.2, so the old default isn't in `configuration.rb` here).

---

## Cross-issue coupling

- **#27 (this) ↔ #26 (adoption guide).** UPGRADING is the *transition* runbook; #26 is the *first-adoption* runbook. They share voice and the SoD-opt-in explanation. Compose by cross-linking: when #26 is planned, it points at `UPGRADING.md#0-1-0-2` for upgraders rather than restating the flip, and this plan's U1 points forward to the adoption guide once it exists.
- **#27 ↔ #24 (denial-behavior docs) / the docs cluster.** Both are documentation issues that pair a doc with a tiny generator/config touch (U3 here mirrors #24's `show_next_steps` edit — a small paired change beside a docs core). They can ship independently and in any order; keep the `warn_on_*` initializer-template additions consistent in style so the two plans don't drift the config-comment conventions.
