# CurrentScope deep review — TL;DR

**Read this file only.** Full detail lives in the other docs in this folder if you need receipts later.

_Refreshed 2026-07-19 after Phase 0 merged to `main` (PR #100 / 0.3.1)._

---

## Do this next (under 2 minutes)

**Phase 0 is done.** Do not re-open the P0 list below for implementation.

**Suggested first pick:** Phase 1 / **#40** — boot-validate `sod_bypass_permission` ∉ `sod_actions`.  
**Why first:** Forbidden misconfig only 500s mid-request today; small, loud, high confidence.

**Then:** **#30** (audit non-UI grants) → **#74** (SoD nil-record nudge) → **#73** (report-mode SoD blind-spot) → **#90** (orphaned scoped grants in the console).

Master checklist: **[08-solid-solution-worklist.md](08-solid-solution-worklist.md)**.

---

## Bottom line (one screen)

| | |
|---|---|
| **Verdict** | Fail-closed core is solid. **No non-admin bypass found.** |
| **Health** | **8.3 / 10** — releasable; not “ship and forget” for regulated prod |
| **On `main` / RubyGems** | **0.3.1** (Phase 0 / PR #100; tagged + published) |
| **Where** | `docs/reviews/grok-whole-app-2026-07-19/` |
| **Phase 0** | **Done** on `main` |
| **Next** | **Phase 1** — loud misconfig + audit honesty (#40, #30, #74, #73, #90, …) |

**What works (keep it):** decision order SoD → full_access → org → scoped → record-less → deny; management UI full_access front door; MutationGuard survives permission skip; #49/#50/#65 escalations closed; symbol `sod_actions` no longer kills SoD; last full-access demote/clear guarded.

**What is still rough:** remaining silent config footguns (boot bypass-in-SoD, audit gaps, report-mode blind-spot), console honesty (orphans), UI empty states / remaining a11y, docs IA, adoption/API surfaces.

---

## DONE — Phase 0 / 0.3.1 (was “before tag P0”)

Shipped in **PR #100** (closes **#91**). Do not re-implement.

| # | Item | Status |
|---|---|---|
| 1 | Normalize `config.sod_actions` | **Done** |
| 2 | Block demoting last full-access role on update | **Done** |
| 3 | Block clearing last full-access org holder | **Done** |
| 4 | `collection_read_actions=` Hash / garbage raise | **Done** |
| 5 | Warn on `destroy_all` / `update_all` in collection_read list | **Done** |

Also landed with that pass: role delete confirm with holder counts; picker/`Set` a11y labels; `private :ambient_collection_model`; Guard purity comment; test pins T1/T3/T4.

---

## LATER — Phase 1+ (still worth it)

Grouped so nothing is dropped. Full IDs live in the [worklist](08-solid-solution-worklist.md).

### Config / security honesty (Phase 1)
| # | Do | Why | Issue |
|---|---|---|---|
| 6 | Boot-validate bypass ∉ `sod_actions` | Mid-request 500 today | **#40** |
| 7 | Audit non-UI grants + honest `request_id` | Ledger holes | **#30** |
| 8 | SoD nil-record nudge via resolver | Diagnostic miss on `params[:id]` | **#74** |
| 9 | Report-mode SoD blind-spot log/ledger | Survey hides the gap | **#73** |
| 10 | Orphaned scoped grants in console | Look like real access | **#90** |

### Docs (Phase 2)
| # | Do | Why | Issue |
|---|---|---|---|
| 11 | Production checklist | Deploy footguns | **#32** |
| 12 | One canonical quickstart | Three incomplete paths | **#25** / **#33** |
| 13 | README → guides + glossary | Overload | **#34** |
| 14 | Docs site / SoD story / agent prompts | Public surface thin | **#98** |
| 15 | UPGRADING + SoD / advisory residuals | Silent posture | **#27** / **#29** / **#36** |

### Admin / a11y still open
| # | Do | Why |
|---|---|---|
| 16 | Empty states on Roles / Events / Subjects | First-run blank tables |
| 17 | Access-denied page: link back to host | Dead-end 403 |
| 18 | Client filter empty: `role="status"` / aria-live | Zero matches not announced |
| 19 | Cascade autosubmit `aria-busy` | Slow frame looks broken |
| 20 | Per-page `<title>` via `content_for` | Every tab says “CurrentScope” |
| 21 | Stable DOM ids on remaining controls | AGENTS.md |

### Tests still open
| # | Do | Why |
|---|---|---|
| 22 | Integration GET: destroy granted record → index forbidden | Empty-list deny pin |
| 23 | Reason-trio includes `:sod_bypassed` (optional order pin) | Happy path already covered |
| 24 | SimpleCov (± mutant) in CI | No line-coverage number |

---

## Do NOT “fix open” (intentional residuals)

Leave these as documented behavior unless product decides otherwise.

| Residual | What it is | Why leave it |
|---|---|---|
| **A5** | Org grant + nil SoD record → veto skipped | Pinned in `sod_nil_record_test`; scoped + report blind spots already closed |
| **A2** | `actor_method` unset without boundary APIs | Cannot fully auto-detect Pretender wiring; loud only at boundary APIs |
| **A6** | `audit = true` + missing table → warn + commit unaudited | Use `:strict` for mandatory audit; degrade is for upgrades |
| **#65 trust** | Wrong `current_scope_model` + scoped full_access opens listed reads | Trusted declaration, same as record hook |
| **Report mode × `:model_undeclared` hard 403** | Not a would_deny row | Deliberate pin in CHANGELOG/tests — do not loosen casually |
| **GatingTripwire opt-in** | Ungated controllers if never included | Auto-include would surprise hosts |

---

## Lens scores (if you want the scoreboard)

| Lens | Score | One line |
|---|---|---|
| Authz / security | 8.5 | No non-admin bypass; host + residual footguns remain |
| Architecture | 8.5 | Clean PDP/PEP; Guard + dual hooks are the debt |
| Frontend / UX | 7.5 | Intentional design; empty states + remaining a11y lag |
| Tests | 8.5 | Strong core matrices; a few pins missing |
| **Overall** | **8.3** | |

---

## Other docs in this folder (only if stuck)

| Open only if… | File |
|---|---|
| You need the master ranked list + disputes | `01-deep-review-main.md` |
| You need attack-surface receipts | `02-security-authz.md` |
| You need architecture “why this shape” | `03-architecture.md` |
| You are fixing UI | `04-frontend-ux.md` |
| You are writing tests | `05-test-audit.md` |
| You want the short action table | `06-recommended-actions.md` |
| **Everything for solid (canonical)** | **`08-solid-solution-worklist.md`** |

Same-day release-gate (diff-only) also lives in the repo at `docs/reviews/*-0.3.0-release-gate-2026-07-19.md` — **not required** for this summary.

---

## Also investigated (issues / caching / docs)

Full note: **[07-issues-caching-docs-investigation.md](07-issues-caching-docs-investigation.md)** (point-in-time snapshot; prefer GH + worklist for status).

| Topic | Takeaway |
|---|---|
| **Open issues** | 27 open after #91 closed; **#98** is the docs-site/SoD-story ticket (now on the worklist as D11). API/React **#96**, Inertia **#97**. Migration **#45**, DX skills **#46**. |
| **Caching today** | Request-scoped org-role memo only. No Solid Cache in the gem. Per-row `allowed_to?` still hits DB → log noise is expected. |
| **Solid Cache** | Optional **host** recipe (Rails 8). Never put cross-request allow/deny in cache without a grant version. |
| **README** | Overloaded; #34 already plans guides + glossary. |

---

## State check

- Review: **done**
- Findings written: **done**
- Issues + caching + docs investigation: **done**
- Phase 0 code fixes: **done** on `main` (PR #100 / 0.3.1)
- Next action: **Phase 1 / #40** (boot-validate bypass ∉ `sod_actions`), or say “do Phase 1” and implement the #40 → #30 → #74 → #73 → #90 stack
