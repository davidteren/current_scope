---
title: Error-isolate subject_label Proc (and signal typo'd Symbol) - Plan
type: fix
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/22
---

# Error-isolate subject_label Proc (and signal typo'd Symbol) - Plan

## Goal Capsule

- **Objective:** stop a host-configured `config.subject_label` **Proc** that raises for a single subject from 500-ing the entire subjects admin page — fall back per subject the way the Symbol branch and the adjacent holder-label helpers already do — and turn a **typo'd Symbol** (a method the subject doesn't respond to) from a silent, page-wide no-op into a one-time log warning. Purely a display-helper robustness fix.
- **Authority hierarchy:** this plan → the settled v0.1 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). The resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **purity** (no writes / no per-decision state), and the ambient `CurrentAttributes` context are **immutable**. This change lives entirely in a view helper (`app/helpers/current_scope/application_helper.rb`) — it touches **no** decision path. The rescue added here is a *display* fallback, never an authorization decision, so it cannot and must not relax fail-closed behaviour anywhere a permission is decided.
- **Stop conditions:** stop and surface rather than guess if (a) the fix would require rescuing anything on a resolver/Guard/catalog path (it must not — this is label rendering only), (b) making the rescue broad would swallow an error that a *decision* relies on (it won't here — the helper only produces a string), or (c) the "warn once" mechanism would need to hold per-request mutable state on a shared object in a way that leaks across requests incorrectly.

---

## Product Contract

> **Product Contract preservation:** confirmed bug, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). The finding was adversarially re-verified against gem source before filing (issue #22); this plan fixes it, it does not re-litigate it.

### Summary

`current_scope_subject_label` (the label shown in the subjects table, the picker, chips, and bulk bar) routes every call through one private helper, `configured_subject_label`. That helper has two asymmetric branches: the **Proc** branch calls the host Proc with **no rescue**, so one subject that trips the Proc (e.g. `->(u) { u.email.upcase }` on a subject whose email is `nil`) raises `NoMethodError`, bubbles up as `ActionView::Template::Error`, and 500s the whole page. The **Symbol** branch is guarded by `respond_to?`, so a typo (`:emial`) never raises — but it silently falls through for *every* subject, giving the admin no signal that their config does nothing. Fix both at the single shared seam: rescue the Proc per subject (fall through to the default human-identifier chain, exactly as a blank-resolving label already does), and warn once when a Symbol names a method the subject doesn't respond to.

### Problem Frame

The subjects page is the admin's primary tool for granting and reviewing roles. A single row of imperfect data (a subject with no email yet) should never take the page down — the file *already* encodes this intent for polymorphic staleness: `current_scope_holder_subject_label` / `current_scope_holder_resource_label` rescue per row (`app/helpers/current_scope/application_helper.rb:52-62`), and `configured_subject_label`'s own Symbol branch is defensive. The Proc branch is the one gap, and the "stated 'must not 500 the page' intent whose rescue only accidentally covers roles/members" (issue evidence) confirms the omission is unintentional, not deliberate. Separately, a config value that silently does nothing for every subject is a Least-Astonishment violation: the admin set `subject_label` expecting a change and got none, with no error and no log.

### Requirements

- **R1.** A `subject_label` **Proc** that raises for a single subject must not 500 the page. That subject's label falls through to the default people-first chain (`email` → `email_address` → `name` → `first+last` → `current_scope_label`); every other subject on the page renders its Proc label normally.
- **R2.** The per-subject rescue is **display-only**. It lives in the label helper and wraps only the host-label evaluation — it never wraps, sits on, or alters any authorization decision path (resolver, Guard, catalog untouched).
- **R3.** A `subject_label` **Symbol** naming a method the subject does **not** respond to emits a **one-time** log warning (naming the configured symbol and pointing at the fix), rather than silently no-opping for every subject. The rendered behaviour is unchanged (still falls through to the default chain) — only the missing signal is added.
- **R4.** Every currently-working case is byte-for-byte unchanged: a valid Symbol renders that attribute; a valid Proc renders its string; a label that *resolves* to nil/blank falls through (unchanged); `nil` subject → `"(none)"`; the default chain when `subject_label` is unset.
- **R5.** `config.subject_label`'s documentation states that a Proc should be **total** (handle every subject) and that a raising Proc or an unresolvable Symbol falls back per subject rather than erroring — so hosts aren't surprised by the new behaviour.

---

## Key Technical Decisions

- **KTD-1 — Fix the one shared seam, not the three call sites.** All three unguarded call sites named in the issue (`app/views/current_scope/subjects/index.html.erb:50`, `app/views/current_scope/scoped_role_assignments/new.html.erb:37` and `:47`) call `current_scope_subject_label`, which calls `configured_subject_label`. One rescue in that private helper protects all of them; a fourth caller added later is covered for free. Patching the views instead would be a larger diff **and** leave any sibling caller still able to 500. The lazy fix *is* the root-cause fix: one guard where every caller routes through.
- **KTD-2 — Rescue `StandardError` on the Proc branch, not just `NameError` (design fork, named).** The reported failure is `NoMethodError` (`nil.upcase`), a `NameError`, which is what the existing holder-label rescue catches. But `subject_label` is **arbitrary host code**: a Proc can raise `ArgumentError`, a `KeyError`, a host-defined error, anything. The requirement is "no single subject 500s the page," so scoping the rescue to the `NameError` family would leave that requirement half-met and re-open the same bug for a differently-broken Proc. **Fork:** (a) `NameError, ActiveRecord::RecordNotFound` — mirrors `current_scope_holder_subject_label` exactly, minimal, but incomplete for R1; (b) `StandardError` — fully satisfies R1 for any host Proc. **Chosen: (b).** This is safe *specifically because this is a label helper* — it produces a display string and nothing downstream branches on it; broad rescue here relaxes no invariant. (Contrast: a `rescue StandardError` on a resolver/Guard path would be a fail-open bug and is explicitly out of bounds — see Goal Capsule.)
- **KTD-3 — Symbol-typo warning is always-on-warn-once, not a new config flag.** Follow the `Event.warn_missing_events_table_once` precedent (`app/models/current_scope/event.rb:82-91`): a clear, one-time misconfiguration warning with the fix named, gated by a boolean so it fires once per process, **no new config surface**. Rejected: gating it behind a `warn_on_*` opt-in like `warn_on_nil_sod_record` — that aid defaults off because the nil-record case is often *legitimate* (collection actions); a Symbol that names a nonexistent method is unambiguously a mistake, so it warrants an unconditional (once) nudge, not an opt-in.
- **KTD-4 — The rescue returns `nil`, merging into the existing fall-through with zero new downstream branches.** `configured_subject_label` already returns `nil` when a label resolves blank, and `current_scope_subject_label` already treats `nil` as "use the default chain." So a rescued Proc failure returns `nil` and rejoins that exact path — no new control flow in the caller, and the `respond_to?` / `public_send` / `.to_s.presence` contract of the working cases is preserved untouched (R4).

---

## Implementation Units

### U1. Error-isolate the configured-label evaluation (the fix)

- **Goal:** wrap the host-supplied label evaluation in `configured_subject_label` so a raising Proc (or a raising Symbol-named method) yields `nil` — falling through to the default chain — instead of 500-ing the page.
- **Requirements:** R1, R2, R4; KTD-1, KTD-2, KTD-4.
- **Dependencies:** none.
- **Files:** `app/helpers/current_scope/application_helper.rb`, `test/helpers/application_helper_test.rb`.
- **Approach:** in `configured_subject_label`, evaluate the Proc branch (`label.call(subject)`) and the Symbol branch (`subject.public_send(label)`) inside a `rescue StandardError` that returns `nil`. Directional shape (the prose is authoritative):

  ```ruby
  def configured_subject_label(subject)
    label = CurrentScope.config.subject_label
    if label.respond_to?(:call)
      label.call(subject).to_s.presence
    elsif label && subject.respond_to?(label)
      subject.public_send(label).to_s.presence
    end
  rescue StandardError
    nil # ponytail: display fallback only — never a decision path; one bad
        # subject falls through to the default chain instead of 500-ing the page
  end
  ```

  `nil` rejoins the existing "resolved blank → default chain" path in `current_scope_subject_label` (KTD-4), so no caller changes.
- **Patterns to follow:** the per-row rescue already in this file — `current_scope_holder_subject_label` / `current_scope_holder_resource_label` (`app/helpers/current_scope/application_helper.rb:52-62`) — widened to `StandardError` because a host Proc is arbitrary code (KTD-2).
- **Execution note (test-first):** this is a robustness/regression fix on a page-availability path — write the failing "Proc raises → falls through, no error" test and watch it go red before editing the helper.
- **Test scenarios:**
  - **Raising Proc, one bad subject:** `subject_label = ->(u) { u.email.upcase }`; subject with `email = nil`, `name = "Ada"` → returns `"Ada"` (default-chain fallback), **no exception** raised. (Reproduces the issue's exact repro.)
  - **Raising Proc, mixed page:** a good subject (`email = "a@b.co"`) and a bad one in the same render → good one labels `"a@b.co"`, bad one falls through; neither raises. (Proves per-subject isolation, not just per-page catch.)
  - **Valid Proc unchanged:** `->(u) { u.email.upcase }` on `email = "a@b.co"` → `"A@B.CO"` (R4).
  - **Symbol-named method raises:** `subject_label = :bad_label` where `bad_label` is defined but raises → falls through to default chain, no exception (KTD-2 covers the Symbol branch too).
  - **nil subject:** `current_scope_subject_label(nil)` → `"(none)"` (R4, unchanged).
- **Verification:** the new helper tests pass; the two existing `application_helper_test.rb` tests still pass; rendering the subjects index with a raising-Proc `subject_label` returns 200 with the bad row showing its fallback label. RuboCop omakase clean.

---

### U2. Warn once on a Symbol subject_label the subject can't answer

- **Goal:** when `subject_label` is a Symbol (truthy, non-callable) that the subject does **not** `respond_to?`, log a one-time warning naming the symbol and the fix — instead of the current silent, page-wide no-op.
- **Requirements:** R3; KTD-3.
- **Dependencies:** U1 (same method; sequence after the rescue lands so the two changes are reviewed distinctly).
- **Files:** `app/helpers/current_scope/application_helper.rb`, `test/helpers/application_helper_test.rb`.
- **Approach:** in the `elsif` chain, when `label` is present and **not** callable but `subject.respond_to?(label)` is false, emit a warn-once before returning `nil`. Storage must survive across requests within a process and be resettable in tests, so key it at module level (helper instances are per-request) — directional: a module-level guard `warn_unknown_subject_label_once(label)` that no-ops after the first call for a given label value, mirroring `Event.warn_missing_events_table_once` (`app/models/current_scope/event.rb:82-91`). Message names the configured symbol and points at the fix ("did you mean a method the subject responds to? / this config is currently a no-op"). Do **not** add a config flag (KTD-3). Preserve the exact `respond_to?` (public) contract — a Symbol naming a private method still warns, consistent with the branch only ever having worked via `public_send`.
- **Patterns to follow:** `Event.warn_missing_events_table_once` — a boolean-guarded, fix-naming, once-per-process `Rails.logger&.warn`.
- **Test scenarios:**
  - **Typo'd Symbol warns once:** `subject_label = :emial`; render two subjects → default-chain labels for both **and** exactly one `Rails.logger.warn` naming `:emial`. (Assert the log via a captured logger; assert only one emission across the two subjects.)
  - **Valid Symbol never warns:** `subject_label = :email` on a subject responding to `email` → no warning (R4).
  - **Behaviour unchanged:** the typo'd-Symbol render still returns the default-chain label (the warning is additive, not a behaviour change — R3).
  - *(Note: tests must clear the module-level warned memo in `setup`/`teardown`, the way an `@…_warned`-guarded warner requires, so ordering doesn't hide a second test's emission.)*
- **Verification:** the warn-once tests pass; a second render in the same process logs nothing further; the label output is identical to before this unit. RuboCop clean.

---

### U3. Document the Proc totality expectation and the fallback

- **Goal:** update `config.subject_label`'s documentation so hosts know a Proc should be total and that a raising Proc / unresolvable Symbol falls back per subject rather than erroring.
- **Requirements:** R5.
- **Dependencies:** U1, U2.
- **Files:** `lib/current_scope/configuration.rb` (the `subject_label` doc comment, `:66-72`), `lib/generators/current_scope/install/templates/initializer.rb` (if it documents `subject_label`), `README.md` (the subject-label subsection, if present).
- **Approach:** extend the existing doc comment to add one honest line: a Proc should handle **every** subject (be total); if it raises for a subject — or a Symbol names a method the subject doesn't respond to — the engine falls back per subject to the default people-first chain rather than erroring, and a typo'd Symbol logs a one-time warning. Mirror the comment style already in `configuration.rb`. Keep it to a few lines; no behaviour claims beyond what U1/U2 implement.
- **Patterns to follow:** the existing `attr_accessor :subject_label` doc block and the surrounding comment voice in `configuration.rb`.
- **Test expectation:** none — documentation only.
- **Verification:** the comment renders and matches the shipped behaviour; the initializer template (if edited) still generates cleanly.

---

## Scope Boundaries

**In scope:** the per-subject rescue in `configured_subject_label` (U1), the one-time typo warning (U2), and the config/README doc note (U3) — all in the display/helper layer.

**Explicit non-goals (preserve deliberate design):**
- No change to any authorization decision path — resolver, Guard, permission catalog, mutation guard, context all stay exactly as they are. This is a label helper only (Goal Capsule, R2).
- No new config surface. The warning is always-on-warn-once (KTD-3), not a `warn_on_*` opt-in.
- No change to the default people-first fallback chain itself, nor to the `nil` subject → `"(none)"` contract (R4).

### Deferred to Follow-Up Work

- **Warn-once on a consistently-raising Proc.** U1 rescues a raising Proc silently (per-row Proc failures are often legitimate data gaps — a nil email — and logging every row on a hot render path would be noise). A single "your subject_label Proc raised for at least one subject; it should be total" once-per-process nudge could be added later if hosts want the signal. Left as an Open Question below rather than built speculatively.
- Auditing the same asymmetry in any *other* configurable host-label seam (none found in this file beyond the ones already rescued) — out of scope unless a second gap surfaces.

---

## Open Questions

- **Should a raising Proc also warn once (not just the typo'd Symbol)?** The issue asks explicitly only for the Symbol warning ("*consider* a one-time log warning when a Symbol subject_label doesn't respond"). A raising Proc is arguably as much a misconfiguration as a typo'd Symbol, but its failures overlap with ordinary sparse data. Defaulting to **silent rescue for the Proc, warn-once for the Symbol** matches the issue and the data-vs-config distinction; flag if the maintainer wants symmetry (both warn once).
- **Warn-once key granularity.** Key the Symbol warning on the label *value* (so re-configuring to a different bad symbol warns again) vs. a single global boolean (warn at most once ever). The per-label key is assumed (matches "this specific symbol is wrong"); confirm if a single global once is preferred for quietness.

---

## Cross-issue coupling

No companion issue. This is a self-contained display-helper robustness fix and does not compose with the denial-behaviour / engine-403 / denial-ergonomics clusters. It shares only a *theme* — "one bad row must not 500 the admin page" — with the polymorphic-staleness rescues **already shipped in the same file** (`current_scope_holder_subject_label` / `current_scope_holder_resource_label`); this change closes the one remaining gap (the Proc branch) in that established pattern, so a reviewer should read U1 as completing existing intent, not introducing a new one.

---

## Sources & Research

- In-repo seams (read 2026-07-15): `app/helpers/current_scope/application_helper.rb` (`configured_subject_label:40-47` — the Proc-vs-Symbol asymmetry; `current_scope_subject_label:18-36` — the fall-through the rescue rejoins; `current_scope_holder_subject_label:52-62` — the per-row rescue pattern), `lib/current_scope/configuration.rb:66-72` (`subject_label` doc), `app/models/current_scope/event.rb:82-91` (`warn_missing_events_table_once` — the warn-once precedent), `lib/current_scope/guard.rb:85-95` (`nudge_on_nil_sod_record` — the opt-in warn contrast).
- Unguarded call sites (all route through the one seam): `app/views/current_scope/subjects/index.html.erb:50`, `app/views/current_scope/scoped_role_assignments/new.html.erb:37,47`.
- House-style reference: `docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`.
