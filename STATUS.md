# STATUS

> Last updated: 2026-07-10

## What this is

**CurrentScope** — a mountable Rails engine for authorization: permissions
auto-derived from `controller#action` routes, roles as editable data, per-record
scoped roles, a non-configurable separation-of-duties (four-eyes) veto, and an
ambient authorization context (`ActiveSupport::CurrentAttributes`) so
`allowed_to?` works identically in controllers, views, and ViewComponents.

- Design concept: [resources/DESIGN.md](resources/DESIGN.md) (captured under the
  placeholder name "Grantwork")
- Research basis: [docs/RESEARCH.md](docs/RESEARCH.md) — palkan / Evil Martians
  on CurrentAttributes vs dry-effects vs explicit passing, Action Policy ideas
- Usage: [README.md](README.md)
- **What's next / gaps / proposals: [docs/ROADMAP.md](docs/ROADMAP.md)** — coverage
  vs open gaps (audit, impersonation/act-as, resource-hierarchy cascade, resolver
  memoization, feature flags) + two proposals: a demo-app redesign and a
  model→record scoped-assignment picker (replacing the raw-GlobalID field).

## Done (v0.1, all committed on `main`)

### Gem (engine at repo root)

- [x] Resolver with fixed decision order: SoD veto → full_access → org-wide
      role → scoped role → default-deny (`lib/current_scope/resolver.rb`)
- [x] PermissionCatalog derived from routes — no permissions table; new
      controllers appear in the grid automatically
- [x] Models: `Role`, `RolePermission`, `RoleAssignment` (one org-wide role per
      subject), `ScopedRoleAssignment` (polymorphic subject + resource)
- [x] Ambient context: `CurrentScope::Current` + `Context` / `Guard` /
      `Permissions` mixins; `TestHelpers#with_current_user`
- [x] Management UI (mounted engine): role editor with controller×action
      permission grid, full-access toggle, subjects page, org-wide + scoped
      (GlobalID-based) assignment; entry restricted to full-access subjects
- [x] `current_scope:install` generator (initializer + mount + next steps);
      standard `current_scope:install:migrations` flow
- [x] Engine test suite against `test/dummy` — 49 runs green; RuboCop omakase clean
- [x] Gem packages cleanly (`gem build`; showcase excluded)

### Hardening (29-agent multi-lens review, 21 confirmed findings fixed)

- [x] SoD fails **loud, not open**: missing `current_scope_initiator` on a
      record hit by an SoD action raises `ConfigurationError` (nil exempts;
      private hooks OK; class-form checks exempt)
- [x] `?id=` query strings can't smuggle a record into collection actions
      (hooks key off `request.path_parameters`; regression-tested)
- [x] `permission_keys=` stages until save — no DB writes before validations
- [x] `allowed_to?` always agrees with the gate under namespaced controllers
      (same-resource controller path wins over the record's route key)
- [x] Guard raises on gating a catalog-excluded controller; Context raises on a
      missing `user_method` (misconfiguration ≠ silent 403)
- [x] Management UI refuses to delete the last full-access role; dead
      scaffolding and the `initiator_method` config knob removed

### Showcase app (now the standalone `current_scope_showcase` repo — Rails 8.1, Hotwire, ViewComponent, built-in auth, no Devise)

- [x] Projects/Reports domain with `approve` flow; `ApproveButtonComponent`
      proves the ambient context (no `current_user` threading)
- [x] Integration + component tests — 25 runs green: RBAC matrix, SoD veto at
      gate and in view, scoped role opens exactly one record, management UI
      locked to full access
- [x] Seeds: `owner@` / `reviewer@` / `member@` / `scoped@example.com`
      (password `password`), each exercising a different mechanism
- [x] **"Harbor master's ledger" design system**: OKLCH tokens (ink cobalt /
      brass pending / stamp-green approved / oxblood denied), IBM Plex,
      approval rendered as a rotated ink stamp with signatory + date, ledger
      tables, four-eyes countersign note, stamp-press approve button,
      engine UI restyled via a single host layout override; verified
      in-browser at desktop and 375px

## Next

1. **Dark mode for the demo** — tokens are OKLCH and centralized; add a
   `prefers-color-scheme: dark` variant (deliberately skipped for v0.1).
2. **Per-request resolver memoization** — repeated `allowed_to?` calls in one
   view re-query; cache the subject's effective permission set on
   `CurrentScope::Current` (DESIGN.md §9.4).
3. **Publish** — push to GitHub, then RubyGems. CI runs the engine suite (`.github/workflows/ci.yml`); the showcase lives in
   its own repo (`davidteren/current_scope_showcase`) with its own CI. Gemspec metadata already points
   at `davidteren/current_scope`.
4. **README screenshots** — the ledger/stamp UI is the best pitch; capture the
   report-approval flow.

## Still to be done (open design questions — DESIGN.md §9)

- [ ] Resource hierarchy / cascade: should "Editor of Project #7" imply rights
      on the project's reports? (traversal, depth, cycles — not designed)
- [ ] Audit / versioning of role edits (who changed which permission, when,
      rollback) — likely needed for a real security control
- [ ] Single vs multiple org-wide roles per subject (currently exactly one, by
      design; union semantics rejected for v0.1)
- [ ] Scoped-role capability restriction (scoped roles currently reuse full
      Role bundles; a restricted per-record capability set is unexplored)
- [ ] Test-helper story for host request specs (a `sign_in_with_role` style
      helper; only `with_current_user` ships today)
- [ ] Pagination for the management UI subjects page (fine until subject
      counts grow; flagged with a `ponytail:` comment)

## Working notes

- Engine test DB: `RAILS_ENV=test bundle exec rake db:create db:migrate` from
  repo root (engine `bin/rails` lacks db commands). Demo is a normal app.
- Integration-test gotcha: after requesting the mounted engine, the session
  keeps its SCRIPT_NAME — use literal paths (`post "/session"`) for host routes.
- Inside the mounted engine, bare host route helpers resolve against engine
  routes — use `main_app.` (bit us once: `request_authentication`).
- Run the showcase (the `current_scope_showcase` sibling repo): `.claude/launch.json`
  config `showcase`, or `cd ../current_scope_showcase && bin/rails server`.
