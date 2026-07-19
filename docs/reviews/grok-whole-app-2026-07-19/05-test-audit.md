# Test-suite audit — whole suite

_2026-07-19 · Builds on `docs/reviews/test-audit-0.3.0-release-gate-2026-07-19.md`. Static mapping only (suite not re-run this session)._

## Verdict

**8.5 / 10 — STRONG.** Trustworthy for a fail-closed authorization engine. Core matrices (SoD order, #49/#50/#65, report-mode positive match, MutationGuard, audit `:strict`, management full_access) are covered, usually unit + request. Prior 0.3.0 config gaps (freeze, destroy_all pin, Hash raise) are closed on the pre-tag worktree.

**No release blocker from test quality alone.** Medium gaps are host-misconfig pins and one request-level empty-list deny.

## Coverage highlights

| Behavior | Status |
|---|---|
| Default-deny / nil subject | COVERED |
| SoD before full_access + `:either` | COVERED |
| Missing initiator raises | COVERED |
| Record-less type bind (#50) + cross-type deny | COVERED |
| Listed reads = scope_for.exists? (#65) | COVERED |
| Non-read full_access barred | COVERED |
| Report mode only `:no_grant` | COVERED |
| Break-glass three-way AND | COVERED |
| A5 residual documented | COVERED (intentional hole) |
| MutationGuard survives permission skip | COVERED |
| Prod impersonation mutations guardrail | COVERED |
| Audit `:strict` rollback | COVERED |
| Last full-access **destroy** | COVERED |
| Last full-access **demote / clear holder** | COVERED (0.3.1 / PR #100) |
| Symbol `sod_actions` still enforces | COVERED (writer + resolver pins, 0.3.1) |
| Empty-list deny after destroy via GET | UNIT-ONLY |
| Non-admin role-assignment/role-update escalation | COVERED (member POST + PATCH); `roles#create` / `scoped_role_assignments#create` as member still open |
| One org-role uniqueness | COVERED (model + schema unique index; no request-level pin on `#create`) |

## Quality smells

**Strong:** config ensure-restore, Current reset after every test, resolver purity `assert_no_difference`, collaborator seams with ensure, no sleep/flaky waits.

**Watch:**
- Prose-pinned diagnostic honesty tests (copy-edit churn)
- System tests still assert user-visible text (AGENTS prefers stable ids)
- `event_test` teardown hardcodes `audit = true`
- No SimpleCov / mutant in CI (hand mapping remains authority)

## Prior gate delta

| Prior 0.3.0 finding | Status on this tree |
|---|---|
| destroy_all characterization | Fixed (`configuration_test`) |
| Writer `.freeze` untested | Fixed |
| Clean list no-warning | Fixed |
| Hash silent un-fix | Fixed on pre-tag branch |
| Empty-list integration deny | **Still open** |
| SoD order equivalent mutant | Still optional |

## Recommended pins (shortest)

1. ~~`sod_actions = [:approve]` still vetoes~~ — **done** in 0.3.1 / PR #100
2. Real GET after destroy → forbidden for scoped full_access index — still open
3. ~~Member POST role_assignment / role update → 403~~ — **done** in 0.3.1 / PR #100
4. ~~Second org RoleAssignment → RecordNotUnique~~ — **done** in 0.3.1 / PR #100
5. Reason-trio includes `[true, :sod_bypassed]` — still open
