# STATUS

> Last updated: 2026-07-14

## What this is

**CurrentScope** — a mountable Rails engine for authorization: permissions
auto-derived from `controller#action` routes, roles as editable data, per-record
scoped roles, an optional separation-of-duties (four-eyes) veto, impersonation/act-as, an
append-only audit ledger, and an ambient authorization context
(`ActiveSupport::CurrentAttributes`) so `allowed_to?` works identically in
controllers, views, and ViewComponents.

- Design concept: [resources/DESIGN.md](resources/DESIGN.md) (captured under the
  placeholder name "Grantwork")
- Research basis: [docs/RESEARCH.md](docs/RESEARCH.md) — palkan / Evil Martians
  on CurrentAttributes vs dry-effects vs explicit passing, Action Policy ideas
- Usage: [README.md](README.md)
- **What's next / gaps / proposals: [docs/ROADMAP.md](docs/ROADMAP.md)**
- Readiness audit: [docs/READINESS-AUDIT.md](docs/READINESS-AUDIT.md) — **complete
  (A1–A13, PR #5); historical, not a worklist.** Kept for its reasoning and for the
  "Verified holding — DO NOT regress" invariants. Current work is in the
  [issues](https://github.com/davidteren/current_scope/issues) + `docs/plans/`
- Showcase app: **[davidteren/current_scope_showcase](https://github.com/davidteren/current_scope_showcase)**
  (own repo; the engine is vendored in-tree there)

Version `0.1.0`. **Not yet published to RubyGems** — the showcase consumes the
engine via an in-tree vendored path gem, and CI needs no external checkout.

## Done (all committed on `main`)

### v0.1 core (engine at repo root)

- [x] Resolver with fixed decision order: SoD veto (or an audited break-glass
      bypass) → full_access → org-wide role → scoped role → scoped role on a
      record-less target → default-deny (`lib/current_scope/resolver.rb`)
- [x] PermissionCatalog derived from routes — no permissions table; new
      controllers appear in the grid automatically
- [x] Models: `Role`, `RolePermission`, `RoleAssignment` (one org-wide role per
      subject), `ScopedRoleAssignment` (polymorphic subject + resource)
- [x] Ambient context: `CurrentScope::Current` + `Context` / `Guard` /
      `Permissions` mixins; `TestHelpers#with_current_user`
- [x] Management UI (mounted engine): role editor with controller×action
      permission grid, full-access toggle, subjects page, org-wide + scoped
      assignment; entry restricted to full-access subjects
- [x] `current_scope:install` generator + `current_scope:install:migrations`
- [x] Gem packages cleanly (`gem build`; showcase excluded)

### Hardening (29-agent multi-lens review, 21 confirmed findings fixed)

- [x] SoD fails **loud, not open**: missing `current_scope_initiator` on a
      record hit by an SoD action raises `ConfigurationError` (nil exempts)
- [x] `?id=` query strings can't smuggle a record into collection actions
      (hooks key off `request.path_parameters`; regression-tested)
- [x] `allowed_to?` always agrees with the gate under namespaced controllers
- [x] Guard raises on gating a catalog-excluded controller; Context raises on a
      missing `user_method` (misconfiguration ≠ silent 403)
- [x] Management UI refuses to delete the last full-access role

### Buildout — PR #3 (extends v0.1 behind config, core model unchanged)

- [x] **Impersonation / act-as**: `CurrentScope::Current` carries `actor` (real)
      alongside `user` (effective subject); permissions resolve against the
      subject, attribution reads the actor. `config.actor_method`;
      `config.sod_identity = :either` (veto fires if either identity initiated
      the record — closes the impersonation self-approval path). Read-only-
      while-impersonating gate (`MutationGuard`) with documented per-controller
      skips; `AccessDenied#reason` (`:sod_veto` / `:no_grant` /
      `:impersonation_gate`) surfaced on `X-Current-Scope-Reason`.
- [x] **Audit event ledger**: append-only `current_scope_events` table (actor +
      subject + target GlobalID strings, denormalized `target_label`, no
      `updated_at`, `readonly?` once persisted). Transactional recording at
      controller mutation sites; read-only events index. Graceful degrade
      (warn-once, no-op) when the table hasn't been migrated; `config.audit`.
- [x] **`scope_for(Model)`**: list-side complement to `allowed_to?` — derives
      the visible relation from the same roles/permissions/scoped grants the
      gate reads (gate/list agreement by construction). Fail-closed, flat.
- [x] **Scoped-role picker** + `CurrentScope::Scopeable` opt-in registry:
      Role → Subject → Resource-type → Record UX (GlobalID stays storage form).

### This session (2026-07-12)

- [x] **SoD is now opt-in**: `config.sod_actions` defaults to `[]` (was
      `%w[approve]`). The engine's baseline is scoped RBAC; enable four-eyes by
      listing actions. `[]` makes the veto a no-op (resolver collapses to
      full_access → org → scoped → deny; no model needs
      `current_scope_initiator`). README + generator reframed as opt-in. (The
      showcase now opts in explicitly.)
- [x] **Production guardrail**: `config.allow_mutations_while_impersonating =
      true` raises at boot in `Rails.env.production` unless
      `ENV["CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS"]` is set —
      privilege-escalation/audit risk fails loudly instead of running silently
      insecure. dev/test/staging unaffected; `false` never raises.
      (`test/configuration_test.rb`)

### Readiness remediation — A1–A13 (branch `feat/readiness-p0`, PR #5)

Worked `docs/READINESS-AUDIT.md` end to end (plan:
`docs/plans/2026-07-12-002-...`), P0→P4, all test-first:

- [x] **P0** — gemspec Rails floor corrected (A1); loud `actor_method` check at
      the impersonation-boundary API (A2); host test helpers `grant_role!` /
      `grant_scoped_role!` (A3).
- [x] **P1** — audit tri-state `config.audit = :strict` (A6); `GatingTripwire`
      mixin for ungated controllers (A4); SoD nil-record characterization +
      opt-in nudge (A5).
- [x] **P2** — `scope_for` STI `base_class` fix (A7); namespaced key-drift docs
      (A8); **Rails floor proven → raised to `>= 8.1`** (A9; `params.expect`
      array semantics need 8.1). Also fixed `with_current_user` restore + test
      isolation.
- [x] **P3** — `config.audit` discoverable (A10); `current_scope:grant` rake
      task (A11); subjects/events pagination (A12·1); picker search hook (A12·2).
- [x] **P4** — CHANGELOG + gemspec metadata; `gem build` warning-clean (A13).

**Engine suite: 181 runs green; RuboCop omakase clean; `gem build` clean.**
PR #5 merged to `main`.

### Admin dashboard UI + role/subject UX — branch `feat/admin-dashboard-ui`, PR #6 (OPEN, not merged)

A large management-UI pass on top of readiness. All `app/`-side (hot-reloads in a
host), self-contained (no web fonts / no build / CSP-safe), opinionated but
overridable. **201 runs green, RuboCop clean.**

- [x] **Light/dark admin dashboard** — sidebar + topbar shell, cobalt accent,
      token theming (`prefers-color-scheme` + a persisted `current_scope_theme` cookie,
      server-rendered → no flash; toggle is a served-asset handler).
- [x] **Permission grid → absolute CRUD matrix** — fixed columns, blank cells
      where a controller doesn't route a column; RESTful 7 fold into
      read/create/update/destroy by default (`config.permission_grid_groups`,
      nil = raw). `CurrentScope::PermissionGrid` PORO expands `controller:group`
      tokens on a separate param channel; raw `permission_keys` still works. A
      ticked cell glows; per-row master toggle.
- [x] **Role descriptions** — `description` column (new migration) + form + index.
- [x] **Subject identity** — `config.subject_label` (Symbol/Proc); default is
      people-first: email → email_address → name → first+last → id.
- [x] **Subjects filter** — client-side, framework-free vanilla JS.
- [x] **Bulk assignment** — multi-select subjects → **bulk scoped role** (picker
      accepts `subject_gids[]`) **and bulk org-wide role** (blank clears).
- [x] **Discoverable scoped revoke** — labeled, confirm-guarded chip control.

**Reload gotcha (host running the engine as a path gem):** `app/` changes
hot-reload; **`lib/` changes (config, resolver, PORO) need a server restart**;
schema changes need `current_scope:install:migrations` + `db:migrate`.

### This session (2026-07-14) — all merged to `main`

Reviewed PR #6 (bots + intent-engineering lenses + a correctness/security/
adversarial cross-model pass), fixed every confirmed finding, then shipped a
run of features and fixes — each its own PR, reviewed, bot-findings addressed,
test-first. Mid-session a **real-app QA gap** surfaced (green unit tests, but the
live UI had a grid-header overlap and a narrow-screen table crush that
`assert_select` can't see); fixed both in a real browser and added a **headless
system-test suite now enforced in CI** so visual/template regressions fail the
build. **Suite now: 243 unit + 19 system green, RuboCop clean.**

- [x] **PR #6** (`65b91c2`) — admin dashboard UI + the review pass: P1 role-save
      privilege-escalation fixed (partial CRUD groups can't silently promote on
      save), bulk subject-class boundary + atomicity + dedup, role-name filter
      correctness, a11y/CSS polish.
- [x] **Members view — PR #7** (`12c11f1`) — each Role lists its org-wide + scoped
      holders with an add-members control (assign from the role side); survives
      stale polymorphic types; org-wide assign returns via `redirect_back_or_to`.
- [x] **v0.2 break-glass — PR #8** (`4d00f69`) — `config.allow_sod_bypass`
      (default off): a privileged, **always-audited** waiver of the SoD veto for
      a flagged record, gated on the initiator holding `bypass_sod`. Resolver
      stays pure (`:sod_bypassed`); Guard records `sod.bypassed` + sets
      `X-Current-Scope-Reason`. Recursion guard (bypass action ∉ `sod_actions`),
      fail-closed hook, no impersonation laundering. README documents it.
- [x] **Resolver memoization — PR #9** (`652710d`) — the org-role lookup is
      memoized on `CurrentScope::Current` (request-scoped), invalidated on any
      `RoleAssignment` write, so a view's N gate checks share one query.
- [x] **Grid header overlap + system tests — PR #10** (`ae90936`) — the sticky
      permission-grid header sat 52px over the first row (a bad PR-#6 offset; its
      sticky container is `.cs-grid-wrap`, so `top` must be 0). Fixed, and added
      the Capybara + cuprite headless system suite + an overlap guard.
- [x] **Subjects table narrow-screen fix — PR #11** (`906d6fe`) — a wide subjects
      table overflowed the page and crushed rows to ~269px on a ~500px window;
      flush-card tables now scroll-x, and below the 820px breakpoint take natural
      width (flat rows). Verified in a real browser both widths.
- [x] **Broadened system coverage + CI — PR #12** (`e0c97dc`) — 17→ system tests
      over the JS/render flows (grid group/partial-guard/row-master, theme toggle
      + persistence, bulk assign, pagination, events ledger, full scoped-picker
      cascade); CI now runs `test:system` in headless Chrome.
- [x] **Deferred P3s + ROADMAP — PR #13** (`0efab4b`) — bulk org-role notice
      counts only actual changes; orphaned assignments removable by id; the
      subjects filter keeps a checked row visible; ROADMAP corrected (audit,
      impersonation, memoization, `scope_for` are shipped).
- [x] **CI action bumps — PR #14** (`fb422fb`) — `actions/checkout`→v7,
      `cache`→v6, `upload-artifact`→v7 (consolidated the three Dependabot majors;
      CI-proven; #1/#2/#4 auto-closed).
- [x] **Subjects server-side search — PR #15** (`e6120e2`) — `?q=` matches every
      subject by identity columns across all pages (was page-scoped client filter
      only). Injection-safe (columns from `column_names`, bound `LIKE` value);
      degrades cleanly when no identity columns exist.

## Next

1. **Publish to RubyGems** — parked (using the vendored/path engine for now).
   Prepped (A13); `gem build` clean, `v0.1.0`. Tag `v0.1.0`, `gem push` (needs
   RubyGems creds), then swap the showcase's `path:` gem for `gem "current_scope"`.
2. **README screenshots** — the UI is clean and verified; capture the dashboard,
   permission grid, subjects, members, events when convenient.
3. Open design questions (DESIGN.md §9): resource hierarchy/cascade,
   multiple org-wide roles, scoped-role capability restriction.

## Still to be done (open design questions — DESIGN.md §9)

- [ ] Resource hierarchy / cascade: should "Editor of Project #7" imply rights
      on the project's reports? (traversal, depth, cycles — not designed)
- [ ] Single vs multiple org-wide roles per subject (currently exactly one, by
      design; union semantics rejected for v0.1)
- [ ] Scoped-role capability restriction (scoped roles currently reuse full
      Role bundles; a restricted per-record capability set is unexplored)
- [x] ~~Host request-spec helper~~ — shipped as `grant_role!` / `grant_scoped_role!` (A3).
- [x] ~~Subjects-page pagination~~ — shipped (A12·1).

## Working notes

- Engine test DB: `RAILS_ENV=test bundle exec rake db:create db:migrate` from
  repo root (engine `bin/rails` lacks db commands).
- Integration-test gotcha: after requesting the mounted engine, the session
  keeps its SCRIPT_NAME — use literal paths (`post "/session"`) for host routes.
- Inside the mounted engine, bare host route helpers resolve against engine
  routes — use `main_app.` (bit us once: `request_authentication`).
- Showcase lives in the sibling repo `current_scope_showcase`; refresh its
  vendored engine copy with `bin/vendor-engine` there when the engine changes.
