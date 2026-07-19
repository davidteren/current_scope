# Security / authorization lens — full findings

_2026-07-19 · Primary lens agent + Augment + READINESS invariants + cubic learnings_

## Verdict

**No confirmed non-admin privilege-escalation path under default config.** Residual risk is almost entirely host misconfiguration and admin self-lockout.

## Decision order (verified)

```
nil subject → deny
SoD (veto | bypass) →
full_access →
org-wide role.grants?(permission) →
scoped grant on THIS record →
record-less scoped (type-bound; listed reads via scope_for.exists?) →
label :model_undeclared / :model_invalid when applicable →
:no_grant
```

Source: `lib/current_scope/resolver.rb:47-75`.

## Attack-surface checklist

| Surface | Result |
|---|---|
| Management UI without full_access | 403 `:not_full_access`; report mode cannot open it |
| Skip `current_scope_check!` only | MutationGuard still runs on engine base |
| Query-string `?id=` on collection | Hooks must use `path_parameters`; regression-tested |
| Non-record hook return (String) | Not record-less → scoped branch closed |
| Cross-type scoped grant on #create | Denied without matching `current_scope_model` type (#50) |
| Scoped full_access on non-list action | Barred (`roles_ticking` excludes full_access) |
| Mass-assignment of permissions | Catalog validation; unknown keys rejected |
| Crafted subject GID of wrong class | `locate_subjects` filters `is_a?(subject_class)` |
| Arbitrary resource_type constantize | Scopeable registry only |
| SQL injection on new sites | Parameterized `where`; type shape-guarded before `base_class` |
| Theme cookie XSS | Allowlisted light/dark before `html_safe` |
| Break-glass recursion | Raises if bypass action ∈ `sod_actions` |
| SoD impersonation self-approval | `:either` weighs actor + subject |

## Medium findings (detail)

### M1 — Symbol `sod_actions` disables SoD
See master review #1. Highest-priority config footgun for fraud control.

### M2 — Last full-access demotion via update
See master #2. `last_full_access?` exists only on destroy path.

### M3 — Clear last full-access holder
See master #3. `clear_org_role` / assignment `destroy` have no holder-count guard.

### M4–M5 — `collection_read_actions` silence / partial mutating list
See master #4–5. Hash path is fail-closed but silent; custom mutating names reintroduce #49 shape.

### M6 — A5 residual (org + nil SoD record)
Pinned intentional fail-open for host misconfig. Scoped path and report-mode blind spot are closed.

### M7 — A2 residual (`actor_method`)
Loud only at impersonation boundary APIs, not at ambient Context resolve.

## Low / residual

- A6 audit degrade (`audit = true` + missing table)
- Trusted wrong `current_scope_model` (#65 KTD-5)
- Bypass key route_key vs controller path drift (fail-closed)
- Org-role memo stale within same request after Role attribute flip
- Subject search LIKE wildcards (admin-only, bound params)
- GatingTripwire opt-in
- Report mode in production (warn-only)

## DO NOT regress (re-verified 2026-07-19)

All items under `docs/READINESS-AUDIT.md` → “Verified holding” remain true, with the refinement that “last full-access role protected” currently means **destroy only**, not demote/clear.

## Dependency note

Same-day security gate cited `rails-html-sanitizer 1.7.0` (GHSA-cj75-f6xr-r4g7). This tree’s `Gemfile.lock` resolves **1.7.1**. Hosts still resolve their own transitive versions — document, do not assume engine lock pins host apps.
