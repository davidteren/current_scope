---
title: Flag a scoped grant that can never match - proven verdict plus a caveated advisory - Plan
type: feat
date: 2026-07-28
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: hand-authored
origin: https://github.com/davidteren/current_scope/issues/134
execution: code
---

# Flag a scoped grant that can never match - proven verdict plus a caveated advisory - Plan

## Goal Capsule

- **Objective:** an operator running report mode can tell three states apart
  before flipping `:enforce` — the subject **needs** a grant, the grant is
  **inert** (#90, its record is gone), or the grant **cannot match** anything.
  Today all three read as an ordinary `would_deny` row with a grant that looks
  correct in the console.
- **Authority hierarchy:** this plan → issue
  [#134](https://github.com/davidteren/current_scope/issues/134) → the
  maintainer decision recorded below → the repo's diagnostic doctrine, which is
  older and outranks the issue's own framing:
  - **"A diagnostic that cries wolf is worse than none"** (`lib/current_scope.rb:189-192`).
  - **Proven-or-silent** — `GatingReflection` asserts only what the callback
    chain states unconditionally, and calls per-action guessing "how a fail-open
    gets reported as gated".
  - **Say only what the predicate proves** — `warn_on_inert_scoped_grant`
    deliberately refuses to claim a grant "would satisfy" an action, because
    "a diagnostic that overstates is how a diagnostic starts being ignored"
    (`guard.rb:523-528`).
- **Delivery posture:** additive and diagnostic only. **No authorization
  decision changes** — nothing here is read by `Resolver#decide` or
  `Guard#current_scope_check!`. Releasable as a patch.

---

## Problem Frame

### The verdict #134 asks for cannot be proven. Verified.

#134 asks to "detect an unresolvable scoped grant statically from the catalog
plus the grants table". Probed on `main` at `ab63832`:

**`current_scope_model` is an instance method**, so the type a controller
resolves to only exists at runtime:

```
ReportsController.respond_to?(:current_scope_model)  => false   (class-level)
private_method_defined?(:current_scope_model)        => true    (instance)
```

`current_scope_record` is the same shape and is worse — its return value can
vary per action. So "which controllers can resolve to type X" is not statically
knowable, and any detector claiming otherwise is guessing.

### The obvious heuristic cries wolf in this repo's own dummy app

The natural rule is "does a ticked key's controller route key match the grant's
type?" — `permission_key` already uses exactly that comparison
(`current_scope.rb:163`). It produces **false positives on `main` today**:

```
Report.model_name.route_key                => "reports"
catalog keys that gate a Report record     => "reports#approve",
                                              "admin/reports#approve",
                                              "nested_reports#index",
                                              "external_id_reports#show"
```

`nested_reports` and `external_id_reports` handle `Report` records and match
neither `reports` nor each other. A grant on a Report whose role ticks only
`nested_reports#index` works, and the heuristic would call it dead.

**Telling an operator to remove a working grant is the worst outcome this
feature can produce** — worse than the silence it replaces, because it spends
the trust the other diagnostics rely on.

### Maintainer decision (2026-07-28)

Ship **both**, visibly separated: a proven verdict, and an advisory that names
its own assumption. Rejected alternatives: proven-only (misses the #108 host's
shape entirely, so the operator who prompted the issue still sees nothing), and
reach-only (accurate but makes the operator do the judging every time).

---

## Requirements

- **R1.** A **proven** verdict is rendered only for a grant that cannot match
  **anything, for any type**. Two shapes qualify, both certain:
  - the role ticks **zero** permission keys and is not `full_access`;
  - **every** key the role ticks is absent from the routed catalog.
- **R2.** A **advisory** signal is rendered when no ticked key's controller
  route key matches the grant's resource type. It must state, in the output
  itself, that only the host's `current_scope_record` hooks can confirm it, and
  name the cross-name-controller false alarm.
- **R3.** The two are **visually and textually distinct**, and neither reuses
  #90's word "inert" — that describes a different failure (the record is gone)
  with a different fix. Three states must be tellable apart: missing, inert,
  cannot-match.
- **R4.** A `full_access` role is never flagged by either rule: it satisfies
  every key by definition.
- **R5.** `bin/rails current_scope:report` gains both sections. Its empty-state
  guard is **ledger-driven and two-way today** (`current_scope_tasks.rake:57`,
  `rows.empty? && blind_rows.empty?`); these categories are **static**, so the
  guard must account for them or the sections never print for the case that
  matters most — a grant created before report mode was ever exercised.
- **R6.** Both surfaces appear in the console on **both** grant surfaces, as #90
  does: the subjects page and the role members view.
- **R7.** **No authorization decision changes.** Nothing here is read by the
  resolver or the Guard.
- **R8.** Diagnostics must not break a request or a task: a resolution failure
  (a missing constant, a DB error) degrades to "no verdict", never raises. Same
  rule `warn_on_inert_scoped_grant` follows at `guard.rb:507`.

---

## Key Technical Decisions

### KTD-1 — One module answers one question, like `GatingReflection`

`CurrentScope::GrantDiagnosis` is the only place that judges a scoped grant.
Two predicates, deliberately separate return values rather than one severity
scale, so a caller cannot accidentally render an advisory as a verdict:

- `verdict_for(grant)` → `:no_permissions` | `:unrouted_permissions` | `nil`
- `type_untargeted?(grant)` → `true` | `false`

### KTD-2 — The advisory is silent whenever the verdict speaks

A role with zero keys is already reported as proven-dead; also reporting "no
ticked key targets this type" would be a second line about the same grant
saying something weaker. Verdict wins; advisory only fires when the verdict is
`nil`.

### KTD-3 — `routed?`, not `include?`

The catalog injects the break-glass key onto rows that route an SoD action, so
`include?` is true for a key nothing routes. `routed?` is the predicate that
answers "could this key ever be gated" (`permission_catalog.rb:64`).

### KTD-4 — The advisory names its own false alarm, in the output

Not in the guide, not in a comment — in the text the operator reads, because
that is where the wrong conclusion gets drawn. This follows
`warn_on_inert_scoped_grant`, which spends four lines refusing to overstate.

---

## Implementation Units

### U1. `CurrentScope::GrantDiagnosis`
- **Files:** `lib/current_scope/grant_diagnosis.rb` (new), `lib/current_scope.rb`, `test/grant_diagnosis_test.rb` (new).
- **Tests:** zero-key role → `:no_permissions`; all-unrouted-key role →
  `:unrouted_permissions`; one routed key → `nil`; `full_access` → `nil` for
  both rules (R4); advisory fires on a type mismatch and is silent when the
  verdict speaks (KTD-2); **`nested_reports#index` on a Report grant is NOT
  flagged** (the false-positive pin from the Problem Frame); unresolvable
  resource class → no verdict, no raise (R8).

### U2. `current_scope:report` sections
- **Files:** `lib/tasks/current_scope_tasks.rake`, `test/tasks/report_task_test.rb` (extend or new).
- **Approach:** compute both categories from the grants table, not the ledger.
  Rewrite the empty-state guard to include them (R5).
- **Tests:** a static-only run (no ledger rows at all) still prints the
  sections — the pin for R5; each section names its fix; the existing
  "No would-be denials recorded" path still prints when everything is clean.

### U3. Console badges
- **Files:** `app/views/current_scope/subjects/index.html.erb`,
  `app/views/current_scope/roles/members.html.erb`, the engine stylesheet,
  `test/system/unresolvable_grant_badge_test.rb` (new).
- **Approach:** follow #90's badge markup and its data-attribute confirm
  pattern; no JS, CSP-safe. Distinct wording per R3.
- **Tests:** system test asserting the proven badge, the advisory badge, and
  that a healthy grant carries neither.

### U4. Docs
- **Files:** `docs/site/limitations.md` (A15 mentions #134 as "not yet flagged"
  — that sentence becomes false), `docs/guides/checking-permissions.md`,
  `CHANGELOG.md`.

---

## Verification Contract

| # | Mutation | Must fail |
|---|----------|-----------|
| 1 | `routed?` → `include?` in the verdict | the injected-bypass-key test (U1) |
| 2 | Let the advisory fire when the verdict is non-nil | the KTD-2 precedence test |
| 3 | Flag a `full_access` role | the R4 test |
| 4 | Drop the route-key match, flag on type name equality | the `nested_reports` false-positive pin |
| 5 | Leave the report task's empty guard two-way | the static-only report test (R5) |
| 6 | Make a resolution failure raise | the R8 degrade test |

---

## Definition of Done

Suite green (**683 unit + 25 system** on `main` at `ab63832`), RuboCop clean,
all six mutations re-run red, R1-R8 each traceable to a test, #134 closed by
the PR.

---

## Scope Boundaries

**Out:** any change to `Resolver#decide` or the Guard (R7); a
`config.warn_on_*` runtime nudge — #134 asks for one, but the runtime already
has `warn_on_inert_scoped_grant` for the adjacent case and this diagnosis is
static, so it belongs where an operator looks *before* traffic, not in a log
line during it; the #108 follow-on shape (a scoped `full_access` grant on a
declared parent, live for its class and inert for children), which needs the
chain semantics and is noted in #134 for a later pass.

## Risks

- **A false positive spends trust that the other diagnostics depend on.**
  Mitigated by the proven/advisory split, by the `nested_reports` pin, and by
  the advisory naming its own false alarm inline.
- **The advisory's route-key rule shares `permission_key`'s documented
  weakness** for namespaced and custom-named controllers. That is deliberate
  consistency, not a new defect, and the output says so.
