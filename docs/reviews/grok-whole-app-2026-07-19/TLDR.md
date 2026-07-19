# CurrentScope deep review — TL;DR

**Read this file only.** Full detail lives in the other docs in this folder if you need receipts later.

---

## Do this next (under 2 minutes)

Open this file and pick **one** P0 item below. Do not open the other review docs yet.

**Suggested first pick:** P0 #1 — Symbol `sod_actions` silently turns SoD off.  
**Why first:** It is a fraud-control silence (initiator can self-approve), small code change, high confidence.

---

## Bottom line (one screen)

| | |
|---|---|
| **Verdict** | Fail-closed core is solid. **No non-admin bypass found.** |
| **Health** | **8.3 / 10** — releasable; not “ship and forget” for regulated prod |
| **Target** | `main` @ `7f8ab12`, version **0.3.0** |
| **Where** | `docs/reviews/grok-whole-app-2026-07-19/` |
| **Time if you only fix P0** | ~1–2 hours + tests |
| **Time if you do P0 + P1** | ~half day |

**What works (keep it):** decision order SoD → full_access → org → scoped → record-less → deny; management UI full_access front door; MutationGuard survives permission skip; #49/#50/#65 escalations closed.

**What is still rough:** silent config footguns, admin self-lockout paths, UI empty states / a11y, a few test pins.

---

## DO NOW — before tag (P0)

Five items. Each is one PR-sized chunk. Do them in this order unless something is already fixed on `chore/0.3.0-pre-tag-fixes`.

### 1. Normalize `config.sod_actions`
- **What:** Writer that stringifies + freezes (like `collection_read_actions=`).
- **Where:** `lib/current_scope/configuration.rb` (plain `attr_accessor` today); match in `resolver.rb` ~464.
- **Why:** `config.sod_actions = [:approve]` makes SoD **never fire** (`[:approve].include?("approve")` is false). Initiator with an org grant can self-approve with no signal.
- **Done when:** Test with `[:approve]` still vetoes (or assignment raises / normalizes).

### 2. Block demoting the last full-access role on update
- **What:** Same guard as destroy, but on role update when unchecking Full access.
- **Where:** `roles_controller.rb` destroy has `last_full_access?`; update does not.
- **Why:** Delete is blocked; uncheck + save on the sole Owner **locks everyone out of the console**.
- **Done when:** Integration test refuses demotion of sole full_access role.

### 3. Block clearing the last full-access org holder
- **What:** Guard clear/destroy of org assignment when no other full_access holder remains.
- **Where:** `role_assignments_controller.rb` `clear_org_role` / `destroy`.
- **Why:** Admin can clear their own (only) Owner assignment and lock the UI forever. Destroy-role is guarded; clear-holder is not.
- **Done when:** Clear of last full_access holder is refused with a clear alert.

### 4. `collection_read_actions=` Hash / garbage members raise
- **What:** Reject non-String/Symbol elements at assignment.
- **Where:** `configuration.rb` writer.
- **Why:** `Array({ index: true }).map(&:to_s)` → never-matching list → **silently restores pre-#65** (fails closed, but silent security-knob death).
- **Status:** Already fixed on `chore/0.3.0-pre-tag-fixes`; still open on pure `main` until that merges.
- **Done when:** Hash assignment raises `ConfigurationError` on main.

### 5. Warn on `destroy_all` / `update_all` in collection_read list
- **What:** Expand `MUTATING_ACTION_NAMES` beyond create/update/destroy.
- **Where:** `configuration.rb` ~216.
- **Why:** Listed actions use full_access-inclusive `scope_for(...).exists?`. A bulk write name on that list reintroduces the #49 type-wide escalation; docs already name `destroy_all`.
- **Done when:** Those names emit the same warn as `create`.

---

## LATER — after tag (P1, still worth it)

All remaining medium/low items, grouped so nothing is dropped.

### Config / API polish
| # | Do | Why |
|---|---|---|
| 6 | `private :ambient_collection_model` | Looks like host API; shows up in `action_methods` |
| 7 | Reword Guard “resolver never reads Current” comment | Org-role memo uses Current — claim is stale and confuses reviewers |
| 8 | Docs: production checklist (`audit: :strict`, `actor_method`, tripwire, leave report mode) | A2/A4/A6 residuals only bite miswired hosts |

### Admin lockout / UI safety
| # | Do | Why |
|---|---|---|
| 9 | Role delete confirm includes holder counts + danger button | Cascade wipes all org + scoped holders; confirm only says “Delete role X?” |
| 10 | Empty states on Roles / Events / Subjects tables | First-run / empty ledger is a silent blank table |
| 11 | Access-denied page: link back to host root | Correctly layout-less, but currently a dead end |

### Accessibility
| # | Do | Why |
|---|---|---|
| 12 | Picker labels with `for=` / `label_tag` | Bare labels fail WCAG association |
| 13 | Subjects row Set: aria-label with subject name | Every row currently sounds like “none / Set” |
| 14 | Client filter empty: `role="status"` / aria-live | Zero matches not announced |
| 15 | Cascade autosubmit: `aria-busy` | Slow frame looks broken |
| 16 | Per-page `<title>` via `content_for` | Every tab says “CurrentScope” |
| 17 | Stable DOM ids on remaining controls (AGENTS.md) | Grid has ids; much of UI still text-coupled |

### Tests (pins that catch fail-opens)
| # | Do | Why |
|---|---|---|
| 18 | Integration GET: destroy granted record → index forbidden | Empty-list deny is unit-only today; filter-chain bugs would stay green |
| 19 | Non-admin POST role/grant mutations → 403 | GETs covered; a future `skip only: :create` would open self-escalation |
| 20 | Second org RoleAssignment → uniqueness failure | Index exists; no regression test if index is dropped |
| 21 | Reason-trio includes `:sod_bypassed` | Optional order pin for break-glass path |

### Product / architecture (when convenient)
| # | Do | Why |
|---|---|---|
| 22 | Dual-hook macro (`current_scope_collection Report`) | Two hooks with asymmetric rules is the #1 adoption hazard |
| 23 | Guard diagnostics extract | Only when the next nudge lands — not “for cleanliness” |
| 24 | Scoped-grant request memo | Only if you measure N+1 on big index pages |
| 25 | SimpleCov (± mutant) in CI | No line-coverage number today |
| 26 | Grant button always visible (disabled + helper until ready) | Vanishing primary is opaque on first use |

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
| Authz / security | 8.5 | No non-admin bypass; host + admin footguns remain |
| Architecture | 8.5 | Clean PDP/PEP; Guard + dual hooks are the debt |
| Frontend / UX | 7.5 | Intentional design; empty states + a11y lag |
| Tests | 8.5 | Strong core matrices; a few pins missing |
| **Overall** | **8.3** | |

---

## Suggested PR stack (when you implement)

1. **PR A — config silence:** items 1, 4, 5  
2. **PR B — last full-access complete:** items 2, 3  
3. **PR C — test pins:** items 18–20  
4. **PR D — UI safety/a11y:** items 9–13  
5. **PR E — polish:** items 6, 7, 16  

Rough: A+B ~2 hours · C ~45 min · D ~1–2 hours · E ~30 min.

---

## Other docs in this folder (only if stuck)

| Open only if… | File |
|---|---|
| You need the master ranked list + disputes | `01-deep-review-main.md` |
| You need attack-surface receipts | `02-security-authz.md` |
| You need architecture “why this shape” | `03-architecture.md` |
| You are fixing UI | `04-frontend-ux.md` |
| You are writing tests | `05-test-audit.md` |
| You want the full action table | `06-recommended-actions.md` |

Same-day release-gate (diff-only) also lives in the repo at `docs/reviews/*-0.3.0-release-gate-2026-07-19.md` — **not required** for this summary.

---

## Master checklist (everything for solid)

**[08-solid-solution-worklist.md](08-solid-solution-worklist.md)** — ~62 actionable items across security, operator honesty, a11y, engine API, tests, docs, adoption/API/Inertia; all 27 open issues mapped; phased path to “solid v1.”

## Also investigated (issues / caching / docs)

Full note: **[07-issues-caching-docs-investigation.md](07-issues-caching-docs-investigation.md)**.

| Topic | Takeaway |
|---|---|
| **Open issues** | 27 open. **#91 = our P0 #1 already filed.** Docs restructure is **#34**. API/React **#96**, Inertia **#97**. Migration **#45**, DX skills **#46**. |
| **Caching today** | Request-scoped org-role memo only. No Solid Cache in the gem. Per-row `allowed_to?` still hits DB → log noise is expected. |
| **Solid Cache** | Optional **host** recipe (Rails 8): Postgres primary + separate cache DB (SQLite SSD or second PG). Never put cross-request allow/deny in cache without a grant version. |
| **README** | Overloaded; #34 already plans guides + glossary. Caching/API/Inertia should be guides, not pitch bulk. |

---

## State check

- Review: **done**  
- Findings written: **done**  
- Issues + caching + docs investigation: **done**  
- Code fixes: **not started**  
- Next action: **P0 #1 / #91 — normalize `sod_actions`**, or say “do P0” and I’ll implement A+B
