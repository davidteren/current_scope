# Architecture lens — CurrentScope v0.3.0

_2026-07-19 · ie-architecture-reviewer + layered-rails judgment + ponytail restraint_

## Verdict

**Architecture health: 8.5 / 10.** Strong layered authorization engine with a
trustworthy PDP/PEP split. Cost is seam bloat and adoption-surface complexity,
not misplaced domain logic.

**One-line:** Fail-closed layered design that earns its complexity; ship 0.3.0
with confidence; pay down Guard accretion and dual-hook DX deliberately.

## Map

| Layer | Location | Role |
|---|---|---|
| PDP | `lib/current_scope/resolver.rb` | Decide allow/deny + `scope_for` |
| PEP | `lib/current_scope/guard.rb` | Enforce, report mode, diagnostics |
| Identity | `context.rb` + `Current` | Host auth → ambient subject/actor |
| Advisory | `permissions.rb` | `allowed_to?` / `scope_for` in views |
| Orthogonal gate | `mutation_guard.rb` | Read-only while impersonating |
| Catalog / grid | `permission_catalog.rb`, `permission_grid.rb` | Route-derived grants + UI |
| Detection | `gating_tripwire.rb`, `gating_reflection.rb` | Ungated discovery |
| Domain | `app/models/current_scope/*` | Thin AR |
| Admin UI | `app/controllers/current_scope/*` | Full-access only |

**Convention:** gemspec `rails >= 8.1` only. No Devise, Pundit, dry-effects, Action Policy. Vanilla Rails first holds.

## Confirmed structural notes

### 🟠 Guard multi-responsibility hub (~500 LOC)
Gate + report mode + three diagnostics + ledger failure handling. Cohesive around “the gate seam,” but every new footgun lands here. Load-bearing ordering: nudges **before** report early-return.

**Fix:** Extract only when the next diagnostic lands; thin orchestrator. Do not extract “for cleanliness” (ponytail).

### 🟠 Dual host hooks are a high-cost contract
`current_scope_record` + `current_scope_model` with asymmetric semantics (NO_RECORD vs nil; model without record is inert; wrong type + scoped full_access is trusted).

**Fix (product):** Single macro e.g. `current_scope_collection Report` when a major allows. Until then keep diagnostics loud.

### 🟠 PDP purity claim vs ambient memo
Resolver uses `Current.memoized_org_role` while Guard comments claim purity. Decision inputs remain pure; lookup cache is ambient.

**Fix:** Reword docs short-term; optional cache collaborator only if jobs need the same memo.

### 🟡 Other
- `Event.record!` ambient-coupled (intentional fail-loud)
- ApplicationHelper diagnostic subsystem size
- Scoped-grant path not request-memoized (ROADMAP 2.4 partial)
- ~~`ambient_collection_model` should be private~~ — **already private** in `Permissions`
- Config surface large but each knob earned — group docs by adoption phase
- Events page: GlobalID actor/subject label lookups from the view (N+1 risk up to two per row; not a clean check)

## Clean checks

- Models thin; no Current-driven decisions in models
- No params/request in `lib/` domain objects
- No unauthorized gems or policy-object zoo
- Fail-closed order intact
- Report mode positive-match closed set

_Note:_ the events index is **not** query-free in the view — labels resolve GlobalIDs per row (follow-up: preload/cache).

## Scores

| Dimension | Score |
|---|---|
| Responsibility placement | 8 |
| Pattern health | 9 |
| Pattern legibility | 8 |
| Coupling restraint | 8 |

## Priority if acting on architecture only

1. Reword purity comment (zero risk)
2. ~~Private `ambient_collection_model`~~ — already done
3. Optional Guard extract when next nudge lands
4. Dual-hook macro before next major
5. Scoped-grant memo only with measured N+1
6. Preload/cache event actor+subject labels (view N+1)
