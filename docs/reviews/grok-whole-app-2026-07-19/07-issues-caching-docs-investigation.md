# Investigation — open issues, caching, DX, docs shape

_2026-07-19 · Context add-on to the whole-app deep review. Not a mandate for
how the gem must run — recommendations for hosts + product direction._

## 1. Open GitHub issues (27) as review context

Source: `GET /repos/davidteren/current_scope/issues?state=open` (27 open).

### Already identified on GitHub (overlap with deep review)

| Issue | Topic | vs deep review |
|---|---|---|
| **#91** | `sod_actions` symbols silently disable SoD | **Same finding as P0 #1** — already filed; do not re-file |
| **#73** | Report-mode SoD blind-spot 403 undiagnosed | Same family as report-mode diagnostic gaps |
| **#74** | Nil-SoD nudge re-derives condition; misses `params[:id]` | Diagnostic honesty; related to silent fail-closed |
| **#90** | Orphaned scoped grants inert but look real in console | Deferred from #65; operator honesty, not PDP hole |
| **#40** | Boot-validate bypass ∉ sod_actions | Loud-config philosophy (plan exists) |
| **#27** | UPGRADING for silent 0.1→0.2 `sod_actions` default flip | Docs/security upgrade visibility |

### Docs / structure (already earmarked — matches your README concern)

| Issue | Topic |
|---|---|
| **#34** | **Restructure README into guides + glossary + internal docs split** (plan: `docs/plans/2026-07-15-016-…`) |
| **#25** | One canonical quickstart (README / site / generator disagree) |
| **#33** | Docs site source in-repo; fix sign-in-bricking quickstart |
| **#24** | Denial behavior end-to-end (JSON, rescue_from, blank 403s) |
| **#28** | Config reference complete both ways |
| **#32** | Security & production checklist |
| **#35** | Testing guide expansions |
| **#31** | Theming docs |

Adoption / migration already tracked:

| Issue | Topic |
|---|---|
| **#45** | Pundit / CanCanCan / Action Policy migration tooling + parity harness |
| **#46** | DX skills (install, doctor, add-resource, why-denied) |
| Guide | `docs/guides/adopting-in-an-existing-app.md` (partial land of #26 cluster) |

### Frontend beyond classic SSR (exactly what you called out)

| Issue | Topic |
|---|---|
| **#96** | **React/Next/API:** `abilities_for(subject)`-style payload; advisory vs authoritative; **caching/staleness** called out in scope; scenario `07_react_api` |
| **#97** | **Inertia:** shared props + denial mid-visit; scenario `08_inertia`; shares payload contract with #96 |

Today the product only supports classic SSR Rails well; #96/#97 are the intentional next product surface for “other frontends / Inertia in-repo React.”

### Not filed as issues (still only in our review)

- Last full-access demotion / clear-holder lockout
- `collection_read_actions` Hash silence (main; fixed on pre-tag branch)
- Mutating-name warn expansion (`destroy_all` / `update_all`)
- Public `ambient_collection_model`
- Request-level empty-list deny test pin
- **No open issue for resolver N+1 / Solid Cache / cross-request grant cache**

Implication: when prioritizing post-review work, **merge review P0s with existing tickets** (#91 first; file lockout as new issues if not already present).

---

## 2. What caching is today (engine truth)

### In the gem — request-scoped only

| What | Where | Lifetime | Invalidation |
|---|---|---|---|
| Org-role lookup | `Current.memoized_org_role` → `RoleAssignment.find_by` once per subject per request | Request / job (`CurrentAttributes`) | `RoleAssignment` after_save/after_destroy → `reset_org_role_cache` |
| Permission catalog keys | `PermissionCatalog#keys` `@keys \|\|= derive` | Process (until catalog reset) | Boot / `reset_catalog!` / route reload |
| Ambient collection model | `Current.collection_model` stashed by Guard | Request | Next request |
| Record-less / scoped EXISTS | **Not memoized** (deliberate — multi-table; stale ALLOW risk) | — | — |
| `Role#grants?` | Live `role_permissions.exists?` per call | — | — |
| Cross-request / Solid / Redis | **None** | — | — |

ROADMAP §2.4 still describes fuller request memo (org role **+** scoped grants + catalog once per request). **Org role shipped (PR #9); scoped path still open.**

Design constraint (intentional product rule):

> Prefer **never cross-request** grant caches that would break “edit a role → effective next load.”  
> Stale allow is worse than extra queries.

Rails query cache still applies: identical SQL in one action can be served from the AR query cache without engine help. That only helps **same SQL string** in one request, not N different `EXISTS` for N rows.

### What that means for logs

A page that calls `allowed_to?(:show, record)` once per row still does:

1. Gate once on the action (1 org-role lookup, memoized thereafter for that subject)
2. Per row: often a **scoped_grant EXISTS** (and possibly more) → **N queries show up in the log**

That is expected with the current design. It is not “broken caching”; it is “authorization answers are live.”

---

## 3. Developer experience: log noise vs production-like behavior

### The pain

In development, every page floods the log with `current_scope_*` / `role_assignments` / `scoped_role_assignments` selects. Developers cannot tell “this is the request’s real cost” from “this is authorization checking every button.”

### What we should **not** do by default

| Temptation | Why avoid as engine default |
|---|---|
| Cache full allow/deny in `Rails.cache` / Solid Cache across requests | Stale ALLOW after revoke is a security bug; invalidation graph is large (roles, permissions, scoped rows, SoD hooks) |
| Put grant decisions on the host’s primary Postgres as a “cache table” without TTL/versioning | Same invalidation problem; now competing with OLTP load |
| Silent in-process global memo of decisions | Multi-user process, test leakage, edit-a-role delay |

Action Policy’s documented approach (also in `docs/RESEARCH.md`): per-request / per-thread memo; **disable cross-request caches in test**; freeze context for safe keys.

### Recommended approach (layered)

Think of three layers. The gem owns 1–2; the host optionally owns 3.

#### Layer 1 — Request memo (engine: keep, finish)

**Status:** org-role done.  
**Next product work (optional, ROADMAP 2.4 remainder):**

- Memo `scoped_grant?(subject, permission, record_gid)` for the request
- Optional: preload scoped grants for a subject once (`WHERE subject = ?`) and answer in memory for that request
- Optional batch API: `allowed_to_many?(action, records)` / use `scope_for` for lists instead of N×`allowed_to?`

**DX tip to document:**  
Prefer `scope_for(Model)` for lists; use per-row `allowed_to?` only for SoD-sensitive actions (already documented in `permissions.rb`).

#### Layer 2 — Query visibility (host + docs; not product core)

Helps logs without changing security:

1. **Tag queries** (ActiveSupport notifications / `ActiveRecord::QueryLogs`) with `/* current_scope */` or a log subscriber that prefixes authz SQL so developers can filter.
2. **Bullet / Prosopite** in development for true N+1 of *host* queries; teach that authz N×EXISTS is a separate class of noise.
3. **Optional dev config** (future): `config.log_authorization_queries = false` that silences only tagged lines — never changes decisions.
4. **`bin/rails dev:cache`** already toggles fragment caching in Rails 8; unrelated to authz unless host fragment-caches partials that embed `allowed_to?` (then fragment cache keys must include permission version — advanced).

#### Layer 3 — Cross-request cache (host recipe only; optional)

For hosts that **measure** hot paths and accept explicit invalidation:

| Store | When it fits | How |
|---|---|---|
| **Solid Cache (SQLite separate DB)** | Rails 8 default story; primary app on **Postgres**, cache on **SSD SQLite** (or second PG DB) | `database.yml` `cache:` role + `config.cache_store = :solid_cache_store` (Rails guides §4) |
| **Solid Cache on Postgres** | Single DB topology, small ops surface | Separate database name, `migrations_paths: db/cache_migrate` |
| **Redis / Memcached** | Multi-app / multi-node already running Redis | Standard `redis_cache_store` |
| **Memory store** | Dev only | Default Rails 8 development |

**What to cache (safe shapes):**

| Safe | Unsafe |
|---|---|
| Catalog of route keys (already process-local) | Per-decision allow/deny without version |
| Subject’s **permission key set** + role id + version of grant graph | Raw AR objects (`Rails.cache` + Role instance) — Rails guide forbids |
| `scope_for` id lists with short TTL **or** an explicit grant-version/counter | Infinite TTL grant payload on the client (#96) without refresh rules |

**Invalidation sketch (if a host opts in):**

```
# Do NOT key only on role_permissions.updated_at — that table has no updated_at,
# and scoped assignment changes would be invisible. Prefer an explicit counter
# (or max of Role/RoleAssignment/ScopedRoleAssignment timestamps + permission
# row presence) bumped on every grant-graph write.
version = CurrentScope.grants_version_for(subject)
Rails.cache.fetch(["cs", subject.to_gid, "keys", version], expires_in: 5.minutes) do
  # load permission keys + full_access flag as primitives
end
```

Bust version on Role / RolePermission / RoleAssignment / ScopedRoleAssignment writes (host callbacks or engine hooks if we ever add optional `ActiveSupport::Notifications` events).

**Solid Cache + Postgres primary (recommended host topology for Rails 8 apps):**

```yaml
# config/database.yml (sketch — host app, not the gem)
production:
  primary:
    adapter: postgresql
    database: app_production
  cache:
    adapter: sqlite3   # or postgresql separate DB
    database: storage/production_cache.sqlite3
    migrations_paths: db/cache_migrate
```

```ruby
# production.rb
config.cache_store = :solid_cache_store
```

This matches Rails 8 guides: Solid Cache is **database-backed ActiveSupport cache**, often a **separate DB** so cache IO does not contend with OLTP. SQLite on local SSD is a first-class documented option; a second Postgres database is fine if ops prefers one engine.

### Production-like development

| Goal | Recipe |
|---|---|
| Feel production query volume | Use realistic fixtures; avoid silencing SQL permanently |
| Feel production **cache** hits | `bin/rails dev:cache` + optionally Solid Cache in development (`cache` DB migrated) |
| Feel production **authz cost** | Leave request memo only; do not use null_store for “quiet logs” if measuring |
| Quiet logs while coding UI | Tagged-query filter or log level, not cross-request authz cache |

**Do not** make the gem require Solid Cache. Document it as:

> “If your host uses Solid Cache (Rails 8 default path), here is a **recommended optional** pattern for caching *grant snapshots*. CurrentScope itself stays request-scoped and fail-closed.”

---

## 4. Relation to #96 / #97 (client payloads)

#96 already scopes **Caching/staleness**: abilities payload is point-in-time; revoked grants must not linger client-side. That is **client advisory cache**, different from server Solid Cache, but the same product rule applies:

- Server gate = authoritative  
- Payload / Inertia props = hide/show UI only  
- Version / ETag / short TTL / re-fetch on navigation  

When implementing #96, reuse the same “grant version” idea for both server optional cache and client payload freshness.

---

## 5. Documentation structure (README overload)

### Current state

- `README.md` is a long single scroll: install, retrofit, usage, scope_for, SoD, break-glass, full config, diagnostics, impersonation, testing, showcase, design.
- Only one deep guide shipped: `docs/guides/adopting-in-an-existing-app.md`.
- `docs/plans/` (30+ plans) and READINESS-AUDIT sit in the same tree adopters browse.
- **#34** already plans the restructure; **#25/#33** own quickstart/site; **#32** production checklist.

### Recommended IA (align with #34, do not invent a third structure)

```
README.md                          # Front door only (~80–120 lines)
  pitch, screenshots, 10-line quickstart, doc map, limitations, license

docs/guides/
  concepts-and-glossary.md         # vocabulary first
  quickstart.md                    # canonical (#25)
  checking-permissions.md          # allowed_to? / scope_for
  separation-of-duties.md
  impersonation.md
  configuration-reference.md       # (#28)
  denial-behavior.md               # (#24)
  testing.md                       # (#35)
  security-and-production.md       # (#32) + caching recommendations section
  adopting-in-an-existing-app.md   # already exists
  migrating-from-pundit.md         # (#45) later
  api-and-javascript-frontends.md  # (#96)
  inertia.md                       # (#97)
  performance-and-caching.md       # NEW — request memo + host Solid Cache recipes (optional)

docs/                              # user-facing
  ROADMAP.md, RESEARCH.md, screenshots/, UPGRADING.md (#27)

docs/internal/                     # contributors only
  READINESS-AUDIT.md, plans/, reviews/

docs/site/                         # (#33) Pages source on main
```

### Caching docs belong in a guide, not the pitch

README one-liner:

> **Performance:** decisions are live and request-memoized for the org role. See [Performance & caching](docs/guides/performance-and-caching.md) for host-side Solid Cache recipes and how to reduce N×`allowed_to?` in views.

### Migration / multi-frontend story

Keep honesty in Limitations:

1. **Today:** SSR Rails (Hotwire) is the supported path.  
2. **Adoption:** report mode + adoption guide + (#45) migration tooling.  
3. **Next:** #96 API payload, #97 Inertia share — same abilities contract, two delivery mechanisms.  
4. **Not yet:** published JS client package (#96 non-goal).

---

## 6. Suggested product directions (priority)

### Do now (already tickets or review P0)

1. Ship **#91** (sod_actions writer) — review P0  
2. Land **#34** README → guides (or a vertical slice: front door + map + one guide) so everything else has a home  
3. File issues for **last full-access demote/clear** if still unfiled  

### Do next (caching / DX without weakening fail-closed)

4. **Document** current memo + “prefer scope_for for lists” (cheap)  
5. Optional engine: request-scoped scoped-grant memo / preload (ROADMAP 2.4 remainder)  
6. Optional engine: `ActiveSupport::Notifications` instrumenter `current_scope.decide` for filtering logs  
7. Guide: host Solid Cache recipe (Postgres primary + SQLite/PG cache DB) — **recommended, not required**  

### Later (product surfaces)

8. #96 abilities payload + staleness  
9. #97 Inertia  
10. #45 migration tooling  
11. #46 doctor/skills  

---

## 7. Answers in one place

| Question | Answer |
|---|---|
| Do we use Solid Cache? | **No, not in the gem.** Hosts on Rails 8 may; document as optional. |
| Best practice if host uses it? | Separate `cache` DB (often SQLite SSD, or second PG); `solid_cache_store`; never cache AR objects; version keys on grant mutations. |
| Hand off to Postgres? | Primary app DB for **authoritative** roles/grants (already). Cache store can be SQLite or a second PG — keep **away** from long-lived authz *decisions* without versioning. |
| Why so many log lines? | Request memo only covers org-role; per-row scoped checks hit the DB. Prefer `scope_for`; optional later request memo for scoped grants. |
| Production-like DX? | Real fixtures + optional `dev:cache` / Solid Cache for host caching; keep authz live; filter logs by tag rather than caching allows. |
| Docs overloaded? | Yes. **#34** is the ticket; split usage / implementation / internal; add caching + API/Inertia guides as those features land. |

---

## 8. State

- Investigation: **done**  
- Engine code changes: **none** (this note only)  
- Next if acting: implement #91 + open “performance-and-caching” guide skeleton under #34, or file lockout issues from review P0
