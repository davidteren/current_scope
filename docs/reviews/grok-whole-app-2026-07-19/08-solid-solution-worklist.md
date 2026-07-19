# Solid-solution worklist — everything to address

_2026-07-19 · Single list merged from: whole-app deep review, 0.3.0 release
gate, 27 open GitHub issues, caching/DX/docs investigation._

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

---

## Track 1 — Silent security / config (must for solid)

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **S1** | Normalize `config.sod_actions` (symbols → strings, freeze; raise on full keys) | `[:approve]` silently disables SoD | R P0 · **#91** | **Done** on `fix/solid-solution-phase-0` |
| **S2** | Refuse demoting last `full_access` role on update | Destroy guarded; uncheck+save locks console | R P0 | **Done** on `fix/solid-solution-phase-0` |
| **S3** | Refuse clearing last full_access org holder | Same lockout via Subjects clear/destroy | R P0 | **Done** on `fix/solid-solution-phase-0` |
| **S4** | `collection_read_actions=` raise on Hash / non-String/Symbol | Silent un-fix of #65 | R P0 · gate | **Done** (pre-tag + this branch) |
| **S5** | Warn on `destroy_all` / `update_all` in collection_read list | #49 shape via config | R P0 · gate | **Done** on `fix/solid-solution-phase-0` |
| **S6** | Boot-validate `sod_bypass_permission` ∉ `sod_actions` | Forbidden misconfig only 500s mid-request | **#40** | Open |
| **S7** | Audit non-UI grants (`grant!`, seeds, rake) + honest `request_id` | Ledger gaps; silent Owner replace via rake | **#30** (bug) | Open |
| **S8** | SoD nil-record nudge: ask `resolver.sod_veto_skipped?`; cover `params[:id]` | Diagnostic silent on common mistake | **#74** | Open |
| **S9** | Report-mode SoD blind-spot 403: log (+ optional distinct ledger signal) | Survey mode hides the gap it must surface | **#73** | Open |
| **S10** | Document (or soft-warn) 0.1→0.2 `sod_actions` default flip | Upgraders silently lose SoD | **#27** | Open (docs) |
| **S11** | Document collection actions in `sod_actions` are no-ops + full_access holds bypass | Silent bulk self-approval hole if misunderstood | **#29** | Open (docs) |
| **S12** | Document advisory `allowed_to?` never consults catalog | Typo keys silent deny/allow asymmetry vs Guard | **#36** | Open (docs) |
| **S13** | Security & production checklist page | excluded=unprotected, 403/404 oracle, deploy footguns | **#32** · R residual A2/A4/A6 | Open |
| **S14** | Dependency hygiene: hosts on sanitizer ≥1.7.1 | Engine lock may be fixed; hosts resolve own tree | R security gate | Document |

---

## Track 2 — Operator / management UI honesty

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **O1** | Orphaned scoped grants: label / cleanup / reap | Inert since #65 but look like real access | **#90** | Open |
| **O2** | Role delete confirm with holder counts + danger button | Cascade wipes all holders; confirm understates | R UX | **Done** on `fix/solid-solution-phase-0` |
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
| **U1** | Scoped picker labels associated (`for=` / `label_tag`) | WCAG 1.3.1 / 3.3.2 | R UX | **Done** on `fix/solid-solution-phase-0` |
| **U2** | Subjects row Set: subject-scoped `aria-label` | Identical controls per row for AT | R UX | **Done** on `fix/solid-solution-phase-0` |
| **U3** | Client filter empty: `role="status"` / aria-live | Zero matches not announced | R UX | Open |
| **U4** | Cascade autosubmit `aria-busy` | Looks broken on slow loads | R UX | Open |
| **U5** | Per-page `<title>` via `content_for` | Every tab says CurrentScope | R UX | Open |
| **U6** | Stable DOM ids on remaining interactive controls | AGENTS.md contract | R UX · T | Open |
| **U7** | Grant button disabled+helper until ready (don’t vanish) | First-use opacity | R UX | Open |

---

## Track 4 — Engine API / correctness polish

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **E1** | `private :ambient_collection_model` | Accidental public host surface | R | **Done** on `fix/solid-solution-phase-0` |
| **E2** | Reword Guard “resolver never reads Current” | Stale purity claim vs org-role memo | R · gate | **Done** on `fix/solid-solution-phase-0` |
| **E3** | Dual-hook macro e.g. `current_scope_collection Report` | Pair record+model; cut adoption footgun | R · C | Open (product) |
| **E4** | Whole-controller / wildcard grants in model API | Grid JS sugar; seeds silently drop | **#42** | Open |
| **E5** | Mis-declared `current_scope_model` diagnostic completeness | Fail closed with clear label/nudge | R gate finding 2 | Partially shipped (`:model_invalid`); verify remaining gaps |
| **E6** | Optional: request-scoped scoped-grant memo / preload | Finish ROADMAP 2.4; cut N×EXISTS | R · C · ROADMAP 2.4 | Open (measure first) |
| **E7** | Optional: instrument `current_scope.decide` for log filtering | DX without caching allows | C | Open |
| **E8** | Guard diagnostics extract (when next nudge lands) | Guard accretion only | R architecture | Defer |

---

## Track 5 — Tests (trust the suite)

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **T1** | Pin symbol `sod_actions` still enforces (with S1) | Fraud-control regression | T · R | **Done** on `fix/solid-solution-phase-0` |
| **T2** | Integration GET: empty-list deny after destroy | Unit-only today | T · gate | Open |
| **T3** | Non-admin POST role/grant mutations → 403 | Self-escalation regression | T · R | **Done** on `fix/solid-solution-phase-0` |
| **T4** | Org-role uniqueness regression test | Schema-only today | T | **Done** on `fix/solid-solution-phase-0` |
| **T5** | Reason-trio includes `:sod_bypassed` | Order pin for break-glass | T | Open |
| **T6** | SimpleCov (± mutant) in CI | Coverage number missing | T · R | Open |
| **T7** | System tests prefer stable ids over text | AGENTS.md | T · U6 | Open |

---

## Track 6 — Documentation & IA (adoptable product)

| ID | Item | Why | Source | Status |
|---|---|---|---|---|
| **D1** | Restructure README → guides + glossary + internal docs | 500+ line overload | **#34** · C | Open (plan exists) |
| **D2** | One canonical quickstart (README / site / generator) | Three incomplete paths; can brick sign-in | **#25** · **#33** | Open |
| **D3** | Docs site source on `main` + accurate claims | Drift + overclaims | **#33** | Open |
| **D4** | Denial behavior end-to-end guide | Blank 403s, JSON, rescue shadowing | **#24** | Open |
| **D5** | Complete config reference both ways | Initializer ↔ README gaps | **#28** | Open |
| **D6** | Testing guide: denials, `actor:`, RSpec | Incomplete host testing story | **#35** | Open |
| **D7** | UPGRADING.md (0.1→0.2 and 0.2→0.3) | Silent posture changes | **#27** · R release notes | Open |
| **D8** | Guide: performance & caching (request memo + host Solid Cache recipe) | Log noise + “how do we cache?” unanswered | C · new | Open — **file or fold into #34** |
| **D9** | Guide: security & production (may merge with S13/#32) | Operable production | **#32** | Open |
| **D10** | Document intentional residuals (A5, A2, A6, trusted model, report×model_undeclared) | Solid means honest limits | R residuals | Partial in README; centralize |

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

### Phase 0 — Pre-tag / immediate (security silence + lockout)
**S1–S5, S2–S3** · tests **T1** · merge pre-tag Hash fix  
*Outcome:* no silent SoD death; no admin console lockout footguns; collection_read knobs loud.

### Phase 1 — Loud misconfig + audit honesty
**S6–S9, S7, O1, O3–O6, E5** · tests **T2–T5**  
*Outcome:* diagnostics tell the truth; ledger and console match reality.

### Phase 2 — Docs solid (adoptable)
**D1–D7, D9–D10, S10–S14**  
*Outcome:* thin README, one quickstart, production checklist, residuals documented.

### Phase 3 — Console quality
**O2, O7–O10, U1–U7, E1–E2**  
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

| Track | Items to address |
|---|---|
| 1 Security / config | 14 |
| 2 Operator honesty | 10 |
| 3 A11y / UI polish | 7 |
| 4 Engine API | 8 |
| 5 Tests | 7 |
| 6 Docs | 10 |
| 7 Adoption / FE | 6 |
| **Total actionable** | **~62** (some merge when landing, e.g. S13↔D9) |
| Explicit non-goals | 8 residuals |

Open GitHub issues covered: **all 27** appear above (mapped into S/O/D/A/E).  
Review-only gaps without issues yet: **S2, S3** (file), **D8** (file or fold into #34), several **U\*** / **T\*** (can ride feature PRs).

---

## Suggested “definition of done” for solid v1

Call the product **solid** (still versioned carefully) when:

1. **Phase 0 + Phase 1** complete (no silent fraud-control / lockout / undiagnosed report gaps).  
2. **Phase 2** complete enough that a new host has one quickstart + production checklist + structured guides (D1, D2, D9 minimum).  
3. Core suite has **T1–T4** green.  
4. #96/#97 may still be open — but Limitations state SSR-first honestly until they ship.

---

## Related pack files

| File | Role |
|---|---|
| [TLDR.md](TLDR.md) | Short start |
| [01-deep-review-main.md](01-deep-review-main.md) | Severity-ranked findings |
| [06-recommended-actions.md](06-recommended-actions.md) | Earlier short action stack |
| [07-issues-caching-docs-investigation.md](07-issues-caching-docs-investigation.md) | Issues + cache + docs IA detail |
| This file | **Master checklist for solid** |
