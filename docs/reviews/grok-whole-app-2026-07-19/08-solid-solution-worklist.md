# Solid-solution worklist — everything to address

_2026-07-19 · Single list merged from: whole-app deep review, 0.3.0 release
gate, open GitHub issues, caching/DX/docs investigation._

_Refreshed 2026-07-19 after **PR #100** merged Phase 0 to `main` as **0.3.1**
(closes #91). Status labels use `main` / PR #100 — not the pre-merge branch
name. Open-issue map rechecked the same day (27 open; #98 added)._

**Purpose:** one checklist to make CurrentScope a **solid** product — safe
fail-closed core *and* something hosts can adopt, operate, and extend without
silent security holes or unfindable docs.

**Sources key:** `R` = review finding · `#N` = GitHub issue · `C` = caching/docs investigation · `T` = test gap

---

## What “solid” means here

| Bar | Meaning |
|---|---|
| **A. Fail-closed core** | No silent weakenings of SoD / grants / admin lockout |
| **B. Loud misconfig** | Host mistakes fail loud or diagnose; not “looks fine” |
| **C. Operator honesty** | Console and reports match reality (orphans, skips, denials) |
| **D. Adoptable** | One quickstart, structured docs, retrofit + migrate paths |
| **E. Operable in prod** | Checklist, audit integrity, production-like DX guidance |
| **F. Extensible surfaces** | API / Inertia supported *contracts*, not every stack on day one |
| **G. Trustworthy suite** | Pins for fail-open-adjacent paths + coverage signal |

Items below are what still stand between “good engine” and that bar.
**Phase 0 is done** — start at **Phase 1**.

---

## Track 1 — Silent security / config (must for solid)

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **S1** | Normalize `config.sod_actions` (symbols → strings, freeze; raise on full keys) | `[:approve]` silently disables SoD | R P0 · **#91** | **Done** — `main` / PR #100 / 0.3.1 |
| **S2** | Refuse demoting last `full_access` role on update | Destroy guarded; uncheck+save locks console | R P0 | **Done** — `main` / PR #100 / 0.3.1 (no separate issue) |
| **S3** | Refuse clearing last full_access org holder | Same lockout via Subjects clear/destroy | R P0 | **Done** — `main` / PR #100 / 0.3.1 (no separate issue) |
| **S4** | `collection_read_actions=` raise on Hash / non-String/Symbol | Silent un-fix of #65 | R P0 · gate | **Done** — pre-tag / #93 + PR #100 |
| **S5** | Warn on `destroy_all` / `update_all` in collection_read list | #49 shape via config | R P0 · gate | **Done** — `main` / PR #100 / 0.3.1 |
| **S6** | Boot-validate `sod_bypass_permission` ∉ `sod_actions` | Forbidden misconfig only 500s mid-request | **#40** | **Done** — `fix/solid-solution-phase-1` |
| **S7** | Audit non-UI grants (`grant!`, seeds, rake) + honest `request_id` | Ledger gaps; silent Owner replace via rake | **#30** (bug) | **Done** — `fix/solid-solution-phase-1` |
| **S8** | SoD nil-record nudge: ask `resolver.sod_veto_skipped?`; cover `params[:id]` | Diagnostic silent on common mistake | **#74** | **Done** — `fix/solid-solution-phase-1` |
| **S9** | Report-mode SoD blind-spot 403: log (+ optional distinct ledger signal) | Survey mode hides the gap it must surface | **#73** | **Done** — `fix/report-mode-sod-blind-spot-73` |
| **S10** | Document (or soft-warn) 0.1→0.2 `sod_actions` default flip | Upgraders silently lose SoD | **#27** | Open (docs) |
| **S11** | Document collection actions in `sod_actions` are no-ops + full_access holds bypass | Silent bulk self-approval hole if misunderstood | **#29** | Open (docs) |
| **S12** | Document advisory `allowed_to?` never consults catalog | Typo keys silent deny/allow asymmetry vs Guard | **#36** | Open (docs) |
| **S13** | Security & production checklist page | excluded=unprotected, 403/404 oracle, deploy footguns | **#32** · R residual A2/A4/A6 | Open |
| **S14** | Dependency hygiene: hosts on sanitizer ≥1.7.1 | Engine lock has 1.7.1; hosts resolve own tree | R security gate | Document (host checklist) |

---

## Track 2 — Operator / management UI honesty

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **O1** | Orphaned scoped grants: label / cleanup / reap | Inert since #65 but look like real access | **#90** | **Done** — PR #104 (label + revoke; Subjects no longer preloads :resource) |
| **O2** | Role delete confirm with holder counts + danger button | Cascade wipes all holders; confirm understates | R UX | **Done** — `main` / PR #100 / 0.3.1 |
| **O3** | `current_scope_skip_gate!(reason:)` + grid shows declared vs bare skip | Unexplained skips must stay alarming | **#76** | Open |
| **O4** | Flag catalog rows whose controller does not resolve | Phantom grants → 500 on hit | **#43** | Open |
| **O5** | Error polish: double org-grant message; excluded regex named | Cryptic failures send people to source | **#44** | Open |
| **O6** | Denial ergonomics: `AccessDenied#permission`, rescue_responses, reason in logs | Operable denials for hosts + APIs | **#39** | Open |
| **O7** | Empty states: Roles / Events / Subjects | First-run silent blank tables | R UX | Open |
| **O8** | Access-denied page: return link to host | Dead-end 403 | R UX | Open |
| **O9** | Permission grid at scale (groups, namespaces, descriptions) | God controllers unusable | **#38** | Open |
| **O10** | Theming docs + views generator | Mechanisms exist, undocumented | **#31** | Open |

---

## Track 3 — Accessibility & UI polish (console quality bar)

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **U1** | Scoped picker labels associated (`for=` / `label_tag`) | WCAG 1.3.1 / 3.3.2 | R UX | **Done** — `main` / PR #100 / 0.3.1 |
| **U2** | Subjects row Set: subject-scoped `aria-label` | Identical controls per row for AT | R UX | **Done** — `main` / PR #100 / 0.3.1 |
| **U3** | Client filter empty: `role="status"` / aria-live | Zero matches not announced | R UX | Open |
| **U4** | Cascade autosubmit `aria-busy` | Looks broken on slow loads | R UX | Open |
| **U5** | Per-page `<title>` via `content_for` | Every tab says CurrentScope | R UX | Open |
| **U6** | Stable DOM ids on remaining interactive controls | AGENTS.md contract | R UX · T | Open |
| **U7** | Grant button disabled+helper until ready (don’t vanish) | First-use opacity | R UX | Open |

---

## Track 4 — Engine API / correctness polish

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **E1** | `private :ambient_collection_model` | Accidental public host surface | R | **Done** — `main` / PR #100 / 0.3.1 |
| **E2** | Reword Guard “resolver never reads Current” | Stale purity claim vs org-role memo | R · gate | **Done** — `main` / PR #100 / 0.3.1 |
| **E3** | Dual-hook macro e.g. `current_scope_collection Report` | Pair record+model; cut adoption footgun | R · C | Open (product) |
| **E4** | Whole-controller / wildcard grants in model API | Grid JS sugar; seeds silently drop | **#42** | Open |
| **E5** | Mis-declared `current_scope_model` diagnostic completeness | Fail closed with clear label/nudge | R gate finding 2 | Partially shipped (`:model_invalid` on main); verify remaining gaps |
| **E6** | Optional: request-scoped scoped-grant memo / preload | Finish ROADMAP 2.4; cut N×EXISTS | R · C · ROADMAP 2.4 | Open (measure first) |
| **E7** | Optional: instrument `current_scope.decide` for log filtering | DX without caching allows | C | Open |
| **E8** | Guard diagnostics extract (when next nudge lands) | Guard accretion only | R architecture | Defer |

---

## Track 5 — Tests (trust the suite)

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **T1** | Pin symbol `sod_actions` still enforces (with S1) | Fraud-control regression | T · R | **Done** — `main` / PR #100 / 0.3.1 |
| **T2** | Integration GET: empty-list deny after destroy | Unit-only today | T · gate | Open |
| **T3** | Non-admin POST role/grant mutations → 403 | Self-escalation regression | T · R | **Done** — `main` / PR #100 / 0.3.1 |
| **T4** | Org-role uniqueness regression test | Schema-only today | T | **Done** — `main` / PR #100 / 0.3.1 |
| **T5** | Reason-trio includes `:sod_bypassed` | Order pin for break-glass (happy path already covered) | T | Open (optional order pin) |
| **T6** | SimpleCov (± mutant) in CI | Coverage number missing | T · R | Open |
| **T7** | System tests prefer stable ids over text | AGENTS.md | T · U6 | Open |

---

## Track 6 — Documentation & IA (adoptable product)

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **D1** | Restructure README → guides + glossary + internal docs | 500+ line overload | **#34** · C | Open (plan exists) |
| **D2** | One canonical quickstart (README / site / generator) | Three incomplete paths; can brick sign-in | **#25** · **#33** | Open |
| **D3** | Docs site source on `main` + accurate claims | Drift + overclaims | **#33** · **#98** | Open |
| **D4** | Denial behavior end-to-end guide | Blank 403s, JSON, rescue shadowing | **#24** | Open |
| **D5** | Complete config reference both ways | Initializer ↔ README gaps | **#28** | Open |
| **D6** | Testing guide: denials, `actor:`, RSpec | Incomplete host testing story | **#35** | Open |
| **D7** | UPGRADING.md (0.1→0.2 and 0.2→0.3) | Silent posture changes | **#27** · R release notes | Open |
| **D8** | Guide: performance & caching (request memo + host Solid Cache recipe) | Log noise + “how do we cache?” unanswered | C · new | Open — **file or fold into #34** |
| **D9** | Guide: security & production (may merge with S13/#32) | Operable production | **#32** | Open |
| **D10** | Document intentional residuals (A5, A2, A6, trusted model, report×model_undeclared) | Solid means honest limits | R residuals | Partial in README; centralize |
| **D11** | Docs site: SoD anti-fraud story, real docs surface, agentic-coding prompts | Public site still thin; agents need copy-paste playbooks | **#98** | Open |

---

## Track 7 — Adoption, migration, multi-frontend

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **A1** | Migration tooling Pundit/CanCan/Action Policy + parity harness | Biggest adoption blocker | **#45** | Open |
| **A2** | DX skills: install, doctor, add-resource, why-denied | First hour + silent gaps | **#46** | Open |
| **A3** | API abilities payload + advisory contract + staleness | Separate JS frontends | **#96** | Open |
| **A4** | Inertia shared props + denial handling | In-repo React/Vue path | **#97** | Open |
| **A5** | Scenario apps for #96/#97 | Living docs | **#96** · **#97** | Open |
| **A6** | Existing adoption guide kept accurate vs report mode + dual hooks | Retrofit path | guide + C | Ongoing |

---

## Track 8 — Explicit non-goals (do not “fix open”)

Document these; do not treat as defects to loosen.

| Residual | Stance |
|---|---|
| A5: org grant + nil SoD record skips veto | Documented; keep fail-closed alternatives loud (S8/S9) |
| A2: `actor_method` only loud at boundary APIs | Document + doctor (#46); no false auto-detect |
| A6: `audit=true` degrades without table | Push `:strict` in checklist (S13); don’t change default without UPGRADING |
| Trusted wrong `current_scope_model` | #65 trade; review like record hook |
| Report mode hard-403 `:model_undeclared` / `:model_invalid` | Deliberate pin — **403 with `X-Current-Scope-Reason` + dev log nudge**, not a report-mode observation row; do not look for a `:report` ledger entry |
| GatingTripwire opt-in | Keep opt-in; recommend in checklist |
| Solid Cache required by gem | Never; host recipe only (D8) |
| Auto-include Guard on every Metal controller | Would surprise hosts |

---

## Phased path to “solid”

### Phase 0 — Security silence + lockout · **DONE**
**S1–S5** · **O2** · **U1–U2** · **E1–E2** · tests **T1, T3, T4**  
Shipped: **PR #100** → `main`, gem **0.3.1** (closes **#91**).  
*Outcome met:* no silent SoD death from symbol lists; no admin console lockout footguns on demote/clear; collection_read knobs loud; cascade delete confirm honest.

### Phase 1 — Loud misconfig + audit honesty · **IN PROGRESS**
**S6–S9, S7, O1, O3–O6, E5** · tests **T2, T5**  
Suggested order: **#40** → **#30** → **#74** → **#73** → **#90**, then **#39 / #43 / #44 / #76**.  
**Landed:** **S6/#40**, **S7/#30**, **S8/#74** (PR #102) · **S9/#73** (PR #103) · **O1/#90** (PR #104).  
Still open: O3–O6, E5, T2/T5.  
*Outcome:* diagnostics tell the truth; ledger and console match reality.

### Phase 2 — Docs solid (adoptable)
**D1–D7, D9–D11, S10–S14**  
Minimum for banner consideration: **D2** (one quickstart) + **D9/S13** (production checklist) + **D1** start. **D11/#98** grows the public docs site.  
*Outcome:* thin README, one quickstart, production checklist, residuals documented.

### Phase 3 — Console quality
**O7–O10, U3–U7** (O2 / U1–U2 already done in Phase 0)  
*Outcome:* admin UI is safe and accessible enough for real operators.

### Phase 4 — Performance / DX (optional but “solid feel”)
**E6–E7, D8**  
*Outcome:* hosts know how to quiet logs and use Solid Cache without caching allows.

### Phase 5 — Expand surface (product complete for multi-stack)
**A1–A5, E3–E4**  
*Outcome:* migrate in, ship API/Inertia with one abilities contract.

### Phase 6 — Suite maturity
**T6–T7** (+ keep mutation hand-probes for load-bearing paths)  
*Outcome:* coverage signal + AGENTS-compliant selectors.

---

## Count

| Track | Rows | Done | Still open-ish |
|---|---|---|---|
| 1 Security / config | 14 | 5 | 9 |
| 2 Operator honesty | 10 | 1 | 9 |
| 3 A11y / UI polish | 7 | 2 | 5 |
| 4 Engine API | 8 | 2 | 6 (incl. Partial/Defer) |
| 5 Tests | 7 | 3 | 4 |
| 6 Docs | 11 | 0 | 11 (incl. Partial) |
| 7 Adoption / FE | 6 | 0 | 6 (incl. Ongoing) |
| **Total** | **63** | **13** | **~50** |
| Explicit non-goals | 8 residuals | — | document, don’t loosen |

**Open GitHub issues (27):** all mapped above — docs/adoption tracks cover **#24–#46** (minus closed), **#73/#74/#76/#90/#96/#97/#98**.  
**Closed since original pack:** **#91** (Phase 0). Historical refs **#49/#65** stay as rationale only.  
**Review-only (no issue yet):** O7, O8, U3–U7, E3, E5–E8, T2, T5–T7, D8, D10, A6, S14 (document-only).

---

## Suggested “definition of done” for solid v1

Call the product **solid** (still versioned carefully) when:

1. **Phase 0** (done) **+ Phase 1** complete (no silent fraud-control / lockout / undiagnosed report gaps).  
2. **Phase 2** complete enough that a new host has one quickstart + production checklist + structured guides (D1, D2, D9 minimum).  
3. Core suite has **T1–T4** green (**T1/T3/T4** done; **T2** still open).  
4. #96/#97 may still be open — but Limitations state SSR-first honestly until they ship.

---

## Related pack files

| File | Role |
|---|---|
| [TLDR.md](TLDR.md) | Short start |
| [01-deep-review-main.md](01-deep-review-main.md) | Severity-ranked findings |
| [06-recommended-actions.md](06-recommended-actions.md) | Earlier short action stack |
| [07-issues-caching-docs-investigation.md](07-issues-caching-docs-investigation.md) | Point-in-time issues/cache/docs investigation — **not** live status |
| This file | **Master checklist for solid** (prefer this + GitHub issues for status) |
