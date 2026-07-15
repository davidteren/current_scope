# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Scoped grants now open a record-less gate** — a subject holding only scoped
  grants was 403'd on every collection action (`#index` and friends), because
  the gate asks the resolver with `record: nil` and the scoped branch required a
  persisted record. The only way in was an org-wide grant, which makes
  `scope_for` return *every* record — so no grant combination produced the
  scoped index the README advertises. A record-less target (nil, or a Class for
  `allowed_to?(:index, Model)`) is now allowed when the subject holds any scoped
  grant whose role ticks the key; `scope_for` is unchanged and still narrows the
  list. Fixed at the shared resolver seam, so the gate and the `allowed_to?`
  view helper agree. (#19)

  **⚠ Upgrade-visible — check your index actions before upgrading.** A scoped
  grant whose role ticks a collection key now opens that gate where it
  previously 403'd. **If a gated `#index` does not call `scope_for`, subjects
  who used to hit a 403 wall will now reach it and see every record the action
  queries.** `scope_for` is guidance, not an enforced constraint, so the engine
  cannot narrow a list the host renders with `Model.all` — the gate only decides
  *whether* the action runs. Before upgrading, for every collection action whose
  key a scoped role ticks, confirm the action scopes its own query. This is the
  one way the fix can expose data rather than merely admit a user.

  Otherwise it grants nothing a role author did not tick, and no decision on a
  persisted record changes — a grant on X still confers nothing on Y, and the
  SoD veto, full_access and org-role paths are untouched. Two further notes:
  the rule is uniform across record-less targets, so a scoped role ticking
  `create` or a bulk key opens those gates too, exactly as an org-wide grant of
  that key already does; and a **scoped `full_access` role does not open
  record-less gates at all** — it satisfies every key, so honoring it here would
  turn one scoped grant into a pass on every `#index` and `#create` in the app.
  It keeps its full authority over its own record.

  Two things this path deliberately will **not** do, both fail-closed: it never
  opens a **separation-of-duties action** (a four-eyes action is
  record-targeted by definition, so a record-less one has no record for the veto
  to measure — it is denied rather than granted with the veto skipped); and it
  never fires for a **member route whose `current_scope_record` is missing or
  returns nil** (`/reports/:id` names a record — if the gate can't get it, that
  is a misconfiguration, not a collection action, and it must not be read as
  "no record needed"). Both keep the pre-0.2.x behavior for misconfigured hosts.

## [0.2.0] - 2026-07-14

### Added
- Impersonation / act-as: `Current` carries the real `actor` alongside the
  effective `user`; `config.actor_method`, `config.sod_identity`, and a
  read-only-while-impersonating `MutationGuard`.
- Append-only audit ledger (`current_scope_events`) with a read-only index.
- `scope_for(Model)` — the list-side complement to `allowed_to?`, from the same
  grants (STI-aware: normalizes to `base_class`).
- Scoped-role picker (Role → Subject → Type → Record) + `CurrentScope::Scopeable`,
  with an opt-in `current_scope_searchable_scope` hook for indexed search.
- Host test helpers `grant_role!` / `grant_scoped_role!` (survive the request cycle).
- `CurrentScope::GatingTripwire` — opt-in mixin that catches ungated controllers.
- `CurrentScope.grant!` + `current_scope:grant` rake task to bootstrap the first admin.
- Pagination for the subjects page and events index.

### Changed
- **Separation of duties is opt-in**: `config.sod_actions` now defaults to `[]`.
- **Declared Rails floor is `>= 8.1`** (the management UI relies on `params.expect`
  array semantics introduced in 8.1); the CI test job exercises it.
- `config.audit` is tri-state: `false | true | :strict`.

### Security
- Production guardrail: `config.allow_mutations_while_impersonating = true` raises
  at boot in production unless `CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS`
  is set.
- The impersonation-boundary API raises when `config.actor_method` is unset,
  instead of silently running with inert act-as security.

### Fixed
- `with_current_user` restores the ambient context correctly across the whole
  `>= 8.1` floor (was version-fragile).

## [0.1.0] - 2026-07-10

### Added
- Initial engine: fail-closed resolver (SoD veto → full_access → org role →
  scoped role → deny), route-derived permission catalog, roles as editable data,
  one org-wide role per subject, per-record scoped roles, a loud separation-of-
  duties veto, an ambient authorization context (`ActiveSupport::CurrentAttributes`)
  so `allowed_to?` works identically in controllers, views, and ViewComponents,
  the mounted management UI, and the `current_scope:install` generator.

[Unreleased]: https://github.com/davidteren/current_scope/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/davidteren/current_scope/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/davidteren/current_scope/releases/tag/v0.1.0
