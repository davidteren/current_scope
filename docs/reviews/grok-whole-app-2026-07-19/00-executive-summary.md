# Executive summary — CurrentScope on `main` (v0.3.0)

_2026-07-19_

## Verdict

**The fail-closed authorization core is trustworthy. No in-gem privilege
escalation path for a non-admin subject was found.** Decision order, SoD
before `full_access`, management-UI front door, MutationGuard separation,
catalog-strict permission writes, subject GID boundary, and the production
impersonation boot-raise all hold.

**Overall health: 8.3 / 10.** Releasable as a gem with residual host-misconfig
and operator-safety work; not “ship and forget” for a regulated production
host without the production checklist.

| Lens | Score | One line |
|---|---|---|
| Authorization / security | **8.5** | No non-admin bypass; residual host SoD / actor_method / admin lockout |
| Architecture | **8.5** | Clean PDP/PEP split; Guard accretion + dual-hook adoption cost |
| Frontend / UX | **7.5** | Intentional design; empty states, cascade-delete copy, a11y associations lag |
| Test suite | **8.5** | Strong core matrices; a few fail-open-adjacent pins still missing |
| Release-gate (0.3.0 delta) | **8.5** | Same-day gate: releasable; 2 config silence items on main |

## What is solid (do not regress)

1. Resolver order: SoD veto → full_access → org → scoped → record-less → deny
2. Record-less closed set (only `nil` or `Class`) — `params[:id]` cannot open the scoped branch
3. #49/#50/#65: type-bound grants; listed reads derive from `scope_for(...).exists?`; non-read bars scoped full_access
4. Report mode lifts **only** `:no_grant` (positive match); SoD blind spot and console stay closed
5. Management UI: every action requires full_access; MutationGuard survives permission skip
6. Last full-access **role destroy** is protected (update demotion + last-holder clear also protected as of 0.3.1 / PR #100)
7. Append-only audit at AR layer; `:strict` rolls back unaudited mutations
8. Vanilla Rails first — no Pundit/Devise/dry-effects in the engine

## Top actions (ordered)

> **Status after 0.3.1 (PR #100):** Phase 0 items below are **shipped**. Do not
> re-implement. Live backlog:
> [08-solid-solution-worklist.md](08-solid-solution-worklist.md) · short start
> [TLDR.md](TLDR.md).

### Before tagging 0.3.0 (high ROI, small diffs) — **DONE on main / 0.3.1**

1. ~~**Normalize `config.sod_actions`**~~ — **Done** (#91 / PR #100).
2. ~~**Guard last full-access on role update / clear last holder**~~ — **Done** (PR #100).
3. ~~**Land pre-tag Hash raise + `destroy_all` warn**~~ — **Done** (#93 + PR #100).
4. ~~**Dependency:** `rails-html-sanitizer >= 1.7.1`~~ — **Done** in engine lock; still document for hosts (S14).

### Soon after tag — **partially done; remainder is Phase 1+**

5. ~~Role delete confirm + picker/`Set` a11y~~ — **Done** PR #100. Empty states / remaining a11y still open (O7–O8, U3–U7).
6. Test pins: ~~symbol `sod_actions`; non-admin POST; org-role uniqueness~~ **Done**. Empty-list deny via real GET still open (**T2**).
7. ~~Guard purity comment~~ — **Done** PR #100.

### Next (Phase 1)

**#40** → **#30** → **#74** → **#73** → **#90** (see worklist).

### Deliberate residuals (document, do not “fix open”)

- A5: org-wide grant + nil SoD record skips veto (pinned in `sod_nil_record_test`)
- A2: `actor_method` silent unless boundary APIs used
- A6: default `audit = true` degrades without events table (use `:strict` for mandatory audit)
- Wrong `current_scope_model` + scoped full_access is a trusted-declaration trade (#65 KTD-5)

## What this pack is / is not

- **Is:** whole-app deep review of main for shipping judgment and a fix backlog
- **Is not:** a re-run of the live test suite (shell unavailable this session); not architecture migration plans (use `dte-arc-plan` next if acting)
- **Next if acting:** Phase 1 on [08-solid-solution-worklist.md](08-solid-solution-worklist.md) (or ranked list in `06-recommended-actions.md` for the short stack)
