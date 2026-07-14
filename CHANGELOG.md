# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
