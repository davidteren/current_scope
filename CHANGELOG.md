# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **The break-glass `bypass_sod` permission is now grantable through the role
  grid**, as the README and `configuration.rb` have always claimed. It isn't a
  routable action, so a route-derived catalog could never contain it: no cell
  existed to tick anywhere in the UI, and a hand-crafted grant was dropped by
  `Role#permission_keys=`. The documented "trusted admin may self-approve" role
  was therefore unbuildable with the shipped tooling — break-glass was reachable
  only through `full_access` (which grants it implicitly along with everything
  else, defeating the point of a *scoped* trusted approver) or a console
  `RolePermission` insert. The catalog now injects the virtual key, which is the
  one seam the grid, the role setter and the Guard all read, so the cell renders
  and the save sticks with no special case in any of them. (#21)

  The column appears only where it can mean something: `config.allow_sod_bypass`
  on, **and** a controller that routes an action listed in `config.sod_actions`.
  With break-glass off (the default) the catalog is byte-for-byte the routed set
  — no new columns, and the key is rejected if assigned. Nothing about the
  resolver, the decision order, or the three live conditions for a bypass
  changed; the permission was always checked correctly, it just couldn't be
  granted.

  The key is named after the **resource**, not the controller path, because that
  is what the resolver looks up (it derives the bypass key from the record's
  `route_key`). So `Admin::ReportsController#approve` contributes
  `reports#bypass_sod` — the key that actually works — and a namespace-only
  resource shows its bypass cell on a `reports` row that no controller routes.

  Known limit: a controller named differently from the records it acts on (an
  `approvals` controller approving `Invoice`s) still contributes an inert
  `approvals#bypass_sod` while the live `invoices#bypass_sod` is not injected.
  Closing that needs to know the SoD-gated model, which the catalog
  deliberately does not load. Tracked in the issue's OQ-2.

  `config.allow_sod_bypass = true` with a blank `config.sod_bypass_permission`
  now raises `ConfigurationError` rather than injecting a malformed key: a
  permission nobody can hold means break-glass is inert while the host believes
  it is armed.

### Changed
- **`Role#permission_keys=` now rejects unknown keys loudly instead of dropping
  them.** A key that isn't in the route-derived catalog makes the role invalid —
  `save` returns `false`, `save!`/`update!` raise `ActiveRecord::RecordInvalid`,
  and `errors[:permission_keys]` names the offending keys. Previously they were
  silently discarded at assignment: a typo (`reports#aprove`), a programmatic
  grant of an unrouted key, or a `db/seeds.rb` granting the never-routed
  break-glass permission all saved cleanly and produced a role that looked
  correct and denied at runtime for no visible reason. Nothing outside the
  catalog was ever persisted, and still isn't — only the signal changed, from
  silence to an error. (#20)

  **Upgrade-visible, and only for programmatic callers.** If you assign literal
  key sets that contain stale keys (from controllers you have since removed),
  those call sites now fail instead of self-cleaning. Name the intent:

  ```ruby
  role.assign_permission_keys(keys, scrub: true)   # drops non-catalog keys, no error
  role.permission_keys_change[:rejected]           # => ["gone#index"]
  ```

  `scrub:` is not reachable through `permission_keys=`, so mass assignment and
  strong params always take the strict path. The management UI is unaffected —
  its grid only ever submits catalog keys, and a role holding a stale key still
  has it cleaned up transparently on save.

  **If a seed grants the break-glass permission, it will now raise — and that is
  the point.** `config.sod_bypass_permission` (default `"bypass_sod"`) is a bare
  action name, not a `controller#action` key, so no route can ever produce it
  and it was silently dropped every time: the role saved cleanly and could never
  bypass. The failure is telling you that grant has never worked. Do **not**
  paper over it with `scrub: true` — that just restores the silent version.
  Making break-glass grantable is tracked in #21.

- `permission_keys_change` gained a `:rejected` array alongside `:added` /
  `:removed`, so a caller that opted into scrubbing can still log what went.

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
  never fires on a controller that **declares no `current_scope_record` hook**.
  A hook returning nil is the host saying "this action has no record", and the
  gate trusts it; no hook says nothing, and reading silence as "collection
  action" would let a controller that forgot the hook hand a scoped subject
  every record of its type. Both keep the pre-0.2.x behavior for misconfigured
  hosts.

  **If a collection-only controller has no hook and you want its gate to honor
  scoped grants, declare one:** `def current_scope_record = nil`. Nothing that
  worked before stops working — without a hook, scoped grants could never open a
  collection gate anyway — but this is the line that opts in.

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
