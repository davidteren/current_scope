# Loop worklist — five-issue batch

type: plan-impl
gate: `bin/rails test` and `bin/rails test:system` and `bin/rubocop` and, when the plan names adapters, `bin/db test`
branch: `<type>/<issue>-<slug>` (examples: `chore/146-coverage-floor`, `refactor/163-polymorphic-registry`)
merge-policy: manual
serial: true
pre-pr-gate: ce-code-review → ie-review → cubic-loop (local) on the exact PR-head SHA, then local CI green, then `gh pr create`. Any later commit voids the gate.
post-pr: wait for remote CI and review bots; re-run the three lenses on the PR; reply inline on every thread with `**Grok:**` (or the agent that is posting); never merge unless the human asks.

## Assumed defaults

- One GitHub issue per branch and per PR. Override: say so before the loop starts that item.
- Merge stays manual. AGENTS.md forbids merge without a human ask. Override: an explicit "merge this PR" in chat.
- Stop on the first red gate. Do not skip ahead. Override: "continue past a red item".
- `--ship` after the pre-PR gate means push and open the PR, not merge.
- STATUS.md last-session handoff updates in the same PR that needs a docs touch, not as a solo main commit.
- System tests run when the item touches UI (issue #164) or when CI would run them. Other items still run `bin/rails test:system` before PR open because AGENTS.md says so when CI would.
- Leftover branch `fix/parent-chain-custom-primary-key` is obsolete. Do not rebase or merge it for issue #150.

## Order and why

1. Issue #146 (coverage floor) first. It changes CI failure behavior. Every later PR inherits the floor and must clear it unmodified.
2. Issue #163 (registry internals) next. It edits `lib/current_scope.rb`, `storable_keys.rb`, and `scoped_role_assignment.rb`. Issue #164 and issue #150 both read those surfaces.
3. Issue #164 (members inert vs deleted) after #163. #163 U2 drops the vestigial `owner:` parameter. #164 already uses a bare `polymorphic_class` call, so either merge order works. Serial order still avoids a rebase on shared CHANGELOG noise.
4. Issue #150 (business primary keys) next. It may touch the preloader that the members page already uses. #156 v2 waits on it. #156 v1 does not, but landing the proof before the large export feature keeps assignment-export from encoding a stale key story.
5. Issue #156 v1 (role-definition export) last. Largest feature. Independent of #150 for v1. v2 stays out of that PR.

File overlap to rebase around: #163 and #150 can both touch `scoped_role_assignment.rb`. Serial order above removes that race. #164 does not need to wait on #163 for correctness.

## Items

- [x] #146 · Minimum coverage floor · status:done · branch:chore/146-coverage-floor · result:PR #173
  Plan: `docs/plans/2026-08-22-004-chore-minimum-coverage-floor-plan.md`
  Units: U1 floor + pin, U2 CONTRIBUTING/CHANGELOG
  Gate extra: `CI=1` in front of both CI-style coverage commands on a fresh `coverage/`
- [x] #163 · Simplify polymorphic registry internals · status:done · branch:refactor/163-polymorphic-registry · result:PR #174
  Plan: `docs/plans/2026-08-22-002-refactor-polymorphic-registry-plan.md`
  Units: U1 one map, U2 drop `owner:`, U3 extract `PolymorphicRegistry` (three commits)
  Gate extra: `bin/db test`; do not absorb #166
- [x] #164 · Members page inert vs deleted · status:done · branch:feat/164-members-inert-vs-deleted · result:PR #175
  Plan: `docs/plans/2026-08-22-003-feat-members-inert-vs-deleted-plan.md`
  Units: U1 classifier, U2 org-wide else branch, U3 zero-subjects empty state, U4 system test + real browser
  Gate extra: `bin/rails test:system`; Chrome verification of the members page
- [x] #150 · Scoped grant business primary keys · status:done · branch:fix/150-business-primary-keys · result:PR #176
  Plan: `docs/plans/2026-08-22-001-fix-scoped-grant-primary-keys-plan.md`
  Units: U1 dummy Ledger/Entry, U2 collision tests, U3 parent chain, U4 docs
  Gate extra: `bin/db test`; do not merge `fix/parent-chain-custom-primary-key`
- [ ] #156 v1 · Portable role-definition export/import · status:pr · branch:feat/156-role-definition-export · result:PR #177
  Plan: `docs/plans/2026-08-13-002-feat-role-definition-export-import-plan.md`
  Units: U1 document+export, U2 diff, U3 apply+lock, U4 snapshot/rollback/ledger, U5 rake+docs
  Gate extra: last-holder lock tests; stay off SchemaGuard `BOOT_EXEMPT_TASKS`; rollback uses `SNAPSHOT=`, not `FILE=`

## Per-item runbook

Copy this for every item. Do not invent a second sequence.

1. Branch from up-to-date `main`. Name it with the pattern above.
2. Read the plan Goal Capsule, then implement units in dependency order. `ce-work` is the executor.
3. After the last unit: local suite + lint the way CI does.
4. Pre-PR gate on that exact HEAD: `/ce-code-review`, then `/ie-review`, then `/cubic-loop` in local mode. Fix findings. If HEAD moves, re-run the gate.
5. Push and `gh pr create`. Title and body open with What / Why / How. Cite the issue (`Closes #N` only when the PR fully does that work).
6. Wait for remote CI and review bots on the head SHA.
7. Re-run the three lenses on the open PR. Fix real findings. Push.
8. Fetch unresolved review threads. Reply inline on every thread with the agent prefix first. Fixed = what changed + SHA. Not fixed = why. Deferred = a GitHub issue number.
9. CI green on the new head. Report readiness in chat. Do not merge.
10. After the human merges: tick the box here, delete the local branch, start the next item from new `main`.

## Trigger

Do not start this loop from a docs-only PR that only lands the plans. Land the plans first. Then, in a new session on `main`, run one item at a time with `ce-work` against that item's plan. After each item, run the pre-PR gate in the header (ce-code-review, then ie-review, then cubic-loop local), then open the PR.

`--ship` on `/dte-arc-work` still means push and open a PR, not merge. Each item must still pass the AGENTS.md pre-PR gate on its own HEAD. Do not treat dte-arc-work as a substitute for that gate.

Stop conditions: first red suite, first unresolved product fork that contradicts a plan, or the human says stop.
