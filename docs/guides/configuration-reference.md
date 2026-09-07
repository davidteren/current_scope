# Configuration reference

> See also: [Concepts & glossary](concepts-and-glossary.md).

## Configuration

Everything lives in `config/initializers/current_scope.rb` (created by the
install generator): the `user_method`, the `subject_class`, `sod_actions`,
`excluded_controllers` (keep infrastructure out of the grid), and
`parent_controller` (what the management UI inherits from).
`management_authorizer` optionally replaces the management console's default
full-access policy. The three
impersonation knobs — `actor_method`, `allow_mutations_while_impersonating`,
and `sod_identity` — are grouped in their own block and covered under
[Impersonation](impersonation.md); they layer in that order, so
`sod_identity` is only observable once a mutation is allowed past the read-only
gate.

Role **definitions** (name, description, `full_access`, permission keys) can
move between environments as YAML. That is not a config knob: see
[Portable role definitions](role-definitions.md). Assignments are not in
that document.

**`config.subject_identity`** — how a subject is identified for portable,
cross-environment use. Default `nil` is the primary key, so existing
installs change nothing. A Symbol names one column (`:email`). An Array of
symbols is a composite (`[:name, :email]`), stored as a list, never a
joined string. An object with `identify(subject)` and `resolve(key)` covers
a key split across tables. A String or Proc is rejected at assignment —
that shape is `subject_label`, which is display-only and fail-soft.
Identity is load-bearing: duplicate natural keys raise `ConfigurationError`
at boot (skipped during `db:` tasks, and skipped for the default primary
key). `resolve` returns nil when missing and never inserts. A blank identity
column raises too: `identify` refuses to mint a key that `resolve` could
never find. `CurrentScope.identify_subject(subject)` and `CurrentScope.resolve_subject(key)`
are the public entry points for the key itself: `identify_subject` returns the
portable key for a record, `resolve_subject` returns the record for a key in
this environment, or nil. `identify_subject` refuses a record that is not
`config.subject_class`, because `resolve_subject` only ever returns one of
those, so a key minted from another model would resolve to a different record.

**Duplicate detection follows your database's collation**, because it compares
your own identity columns. MySQL's default collation is case-insensitive, so
`Ada@example.com` and `ada@example.com` count as one duplicate key there and as
two distinct keys on PostgreSQL and SQLite. Each database stays self-consistent
(`resolve` matches under the same rules), but a host that tests on SQLite and
deploys on MySQL can meet a boot refusal that CI never showed. Run
`current_scope:identity:check` against a copy of production data, or use a
case-insensitive unique index, if that difference matters to you.

For a Symbol or Array identity, put a plain unique index on exactly those
columns and the boot check answers from the index, without scanning the
subject table.
Without one it is a grouping query over the subject table. An identity
OBJECT owns its own `unique?`, so boot pays whatever that method costs.
To list every duplicate, run `bin/rails current_scope:identity:check`. Guided attach:
`bin/rails current_scope:identity:setup IDENTITY=email SUBJECT=you@example.com`
(dry-run) then `WRITE=1` to call `grant!`. `PLACEHOLDER=1` needs a
`create_placeholder!` factory on the identity object from
`bin/rails generate current_scope:identity`; without one the task stops
with "PLACEHOLDER=1 has no factory". With a factory it writes a marked row
only together with `WRITE=1`, and only outside production. Never invent a
production subject.

**`config.subject_label`** is not the same knob. Label names a subject in
the management UI and is allowed to fail soft. Pointing both at `:email`
does not make the label a resolver.

**`config.polymorphic_class_names`** — optional Hash of stored type token to
class name, for a custom `polymorphic_name` that Rails cannot reverse. Default
`{}`. Auto-detected overrides (loaded models whose token is not the Rails
default name) merge with this map. Auto-detection sees only the models loaded
when the registry rebuilds: under `eager_load` (production) that is every model,
so the map is authoritative; in development a custom-token model autoloaded
after boot is not reverse-resolvable until the next reload. Map a token here when
it must resolve regardless of load timing. Two classes that claim the same token
raise at rebuild, including a shortened name that matches another loaded class.
The named class must actually store that token; an unknown class name raises.
A token is the stored grant identity: if you retire a model and later give its
token to a different class, existing grants rebind to the new class, so treat a
token rename or reuse as a data migration.

**`config.enforcement`** — `:enforce` (default) | `:report`. What the gate does
with a denial. `:enforce` means a denial is a 403; it is the only production
posture. `:report` logs a *missing grant* and lets the request through instead,
recording it as `access.would_deny` — the adoption ramp for retrofitting an
existing app, covered in
[Adopting CurrentScope in an existing app](adopting-in-an-existing-app.md)
and the short retrofit recipe in the README Installation section. It relaxes
nothing else: the SoD veto and the management console are untouched by it. An
unknown value raises at boot rather than being silently treated as one of the
two — believing you're enforcing when you aren't is the worst way to be wrong
about this setting.

**`config.collection_read_actions`** — `["index"]` by default. The record-less
actions whose gate derives its answer from the scoped list, so a scoped
`full_access` grant opens exactly the collections that would show its records
(gate and list agree by construction — the #65 fix). Set `[]` to restore the
pre-#65 behavior, where explicit ticks still open type-bound record-less gates
but scoped `full_access` opens none (the whole record-less family is new in
this release — no released version had either posture). A full key
(`"reports#index"`) raises at assignment (the list is action-segment matched,
app-wide), and a canonical mutating name (`create`/`update`/`destroy`) logs a
loud warning.
**List-narrowing reads only:** never name a mutating action here — that would
hand a scoped full_access holder the action on every record of the type off a
grant on one record. Custom read actions (`export`, `search`) are the intended
additions. Members normalize to strings on assignment, so `%i[index]` works.

The **audit ledger** is controlled by `config.audit` — tri-state
`false | true | :strict`. `false` records nothing; `true` (the default) records
authorization changes made through the **management UI**, the **impersonation
boundary**, and **`CurrentScope.grant!`** (including the rake task and seeds
bootstrap path — self-attributed, `details.source = "bootstrap"`), and degrades
gracefully (skip + warn once) if the events table isn't migrated; `:strict`
**raises** on a missing events table so an audit-mandatory app never commits an
unaudited change (the mutation rolls back).

Since #182 the ledger no longer depends on which door a GRANT was created or
destroyed through (updates are a separate matter — see the table below).
`scoped_role.granted`, `scoped_role.revoked`, `org_role.removed` and
`role.deleted` are emitted from model callbacks, so a seed, a rake task, a
console one-liner and the `grant_scoped_role!` test helper all record what the
management UI records. (`grant_role!` is a direct `RoleAssignment.create!`, and
org-role creation is one of the five writes named below as still unrecorded.)
Every event that CHANGES an authorization carries `details.attribution` —
`org_role.assigned`, `org_role.changed`, `org_role.removed`, `role.created`,
`role.updated`, `role.renamed`, `role.deleted`, `scoped_role.granted` and
`scoped_role.revoked`. It is `"actor"` when an ambient identity existed
(`Current.actor` answers `super || user`, so a request, a job, an ambient user
or `with_current_user` in a test all produce it), `"self"` when none did, in
which case the row is self-attributed to the record it is about.
`CurrentScope.grant!`'s rows are self-attributed too, so they read `"self"`;
what marks them as the bootstrap path is their separate `source: "bootstrap"`.

It is `attribution` and not `source` because `details["source"]` was already
taken, twice and for different things: `CurrentScope.grant!` writes
`source: "bootstrap"`, and `definitions.applied` / `definitions.rolled_back`
write the file path the document came from. Filter on `attribution` to isolate
who was behind an authorization change; filter on `source` for neither.

The OBSERVATION events carry no attribution and are not meant to:
`impersonation.started` / `.stopped`, `sod.bypassed`, `access.would_deny`,
`access.sod_blind_spot` and `access.sod_initiator_missing` record what happened
at the gate rather than a change to a grant. The two definitions events are
authorization changes and carry no `attribution` either — their actor is the
one the document was applied with. Do not read an absent `attribution` as
"not a human".

What is recorded from the model is **creation and destruction of scoped
grants**, and **destruction** of org-role assignments and of roles. Five write
paths are still silent, and it is worth knowing which before you rely on the
ledger:

| Write | Recorded? |
|---|---|
| `ScopedRoleAssignment` create / destroy | yes, from the model |
| `ScopedRoleAssignment#update!` direct (`role:`, `subject:`, `resource:`) | no — the callbacks are `after_create` and `after_destroy`; re-pointing a live scoped grant leaves no row |
| `RoleAssignment` destroy, `Role` destroy | yes, from the model |
| `RoleAssignment.create!` direct | no — `CurrentScope.grant!` is the documented path and carries the from/to a callback cannot see |
| `RoleAssignment#update!(role:)` direct | no — same reason; a console re-grant leaves no trail |
| `Role.create!` direct | no — `role.created` carries the initial permission set, which is not persisted when an `after_create` runs, and moving it to `after_commit` would forfeit the `:strict` rollback |
| `Role#update!` direct (`full_access`, `permission_keys`) | no — `role.updated` / `role.renamed` are emitted by the console |

So a privilege change made by `update!` in a console or a seed still leaves no
row. Use the management UI, `CurrentScope.grant!` or the definitions document
for changes that must be auditable.

UI events stamp `request_id` from `ActionDispatch::RequestId` via the Context
hook.

> **Note on the `!`:** despite the bang, `Event.record!` only guarantees
> raise-on-failure under `:strict` (and for a missing actor). In the default
> `true` mode a missing events table is a warn-once no-op, and under `false`
> every call silently returns `nil` — so a mutation-wrapping transaction does
> **not** roll back on a failed audit write unless you opt into `:strict`.

## Management authorization

**`config.management_authorizer`** defaults to `nil`: only subjects with an
organization-wide `full_access` role can enter or change the console. Set a
callable to delegate role administration under a host policy. It receives the
effective subject as its positional argument and `action:`, `role:` and
`target:` keywords. Only literal `true` permits the operation. A configured
callback also decides for full-access subjects; they do not bypass it.

```ruby
CurrentScope.configure do |config|
  config.management_authorizer = lambda do |subject, action:, role:, target:|
    RoleAdministration.allowed?(subject, action: action, role: role, target: target)
  end
end

CurrentScope.can_manage?(:update_role, subject: editor, role: proposed_role)
CurrentScope.can_manage?(:assign_scoped_role, subject: editor, role: reviewer_role,
                        target: recipient)
```

`RoleAdministration` in this example is a host-defined policy. The engine does
not impose an administrator tier, a held-permission ceiling, or protected
recipient rules; the host must implement those requirements in its callback.
The callback does not replace application permissions or the impersonation
mutation gate. The console retains its last-full-access-holder protections.

| Action | Decision context |
|---|---|
| `:access` | Console entry; `role` and `target` are `nil`. |
| `:create_role`, `:update_role`, `:destroy_role` | The role being created, edited or deleted; `target` is `nil`. |
| `:assign_role`, `:revoke_role` | The organization-wide role and recipient. Clearing an absent assignment can supply `role: nil`. |
| `:assign_scoped_role`, `:revoke_scoped_role` | The scoped role and recipient. |

For scoped operations, `target` is the **recipient**, not the resource. The
callback receives no resource keyword. This API supports role- and
recipient-based delegation; it cannot express resource-specific console
administration rules. Resource-type compatibility is a separate declaration,
described below.

**Keep the callback a pure predicate.** It can run several times for one
request, including when rendering controls. Role updates check both the saved
role and a candidate carrying submitted attributes and permission keys. The
full-access checkbox checks a separate candidate with `full_access = true`,
even when the user has not selected it. Existing-role candidates keep their
persisted identity. Do not save candidates, emit audit events or consume a
quota from this callback; an authorization question is not a completed write.
`role` and `target` can be `nil`, including for unavailable assignment subjects.

**`CurrentScope.can_manage?`** accepts
`(action = :access, subject: CurrentScope::Current.user, role: nil, target: nil)`
and returns a boolean without performing the operation. A missing subject is
denied. With no callback it checks the subject's full-access role; otherwise it
calls the configured predicate. A non-callable setting raises
`CurrentScope::ConfigurationError` when checked. A configured-policy denial
uses `AccessDenied#reason == :management_denied`; the default policy uses
`:not_full_access`. `enforcement = :report` does not relax either policy.
Direct model writes and `CurrentScope.grant!` do not call this management
predicate; host write paths must authorize their own callers.

Bulk console grants lock recipients before role and assignment rows. The
recipient order is lexical by `[subject.class.base_class.name, subject.id.to_s]`,
so an integer id of `10` precedes `2`. Host transactions that lock several
recipients and then grant roles should use the same order to avoid lock cycles.

## Resource permission ceilings

**`current_scope_grantable_permissions`** limits the permission keys a role may
carry when granted on a resource type. Include `CurrentScope::Scopeable` for
picker support, or `CurrentScope::GrantableRoles` for the rule without browsing:

```ruby
class Project < ApplicationRecord
  include CurrentScope::Scopeable
  self.current_scope_grantable_permissions = %w[projects#show projects#update]
end
```

A non-full-access role whose entire bundle is within this ceiling can be
granted on a Project, including a newly created or renamed role. The declaration
does not grant any permission by itself. Keys normalize to unique nonblank
strings. A subclass inherits the declaration unless it supplies its own;
`nil` means inherit, or no ceiling when no ancestor declares one. `[]` refuses
every role. A nonempty ceiling accepts an empty role bundle, but always refuses
`full_access` roles. If `current_scope_grantable_roles` also lists allowed role
names, a scoped assignment write must satisfy both declarations. For existing
holders, `current_scope_grants_role_permissions?(role)` checks the permission
ceiling alone; the default name list does not block a role rename or safe bundle
edit. Hosts that override `current_scope_grants_role?` retain their custom
compatibility rule.

Scoped-assignment validation checks the saved bundle for an existing role and
the proposed bundle for a new role before it is saved. Role bundle edits and
direct role-permission writes also reject changes that exceed the ceilings of
existing scoped holders. These are model validations, not database
constraints. Adding a declaration does not rewrite or revoke existing grants;
use `bin/rails current_scope:report` to identify incompatible assignments and
remove or correct them. See
[Scopeable models](checking-permissions.md#scopeable-models) for the name-based
declaration and resource picker.

## Batch authorization for one record

**`CurrentScope.resolver.allowed_subjects`** answers the same record-bound
permission question for several subjects:

```ruby
approvers = CurrentScope.resolver.allowed_subjects(
  subjects: candidates, permission: "projects#approve", record: project
)
```

The signature is `(subjects:, permission:, record:, actor: nil, cascade: true)`.
Supply an ActiveRecord record instance; a class or `nil` raises `ArgumentError`.
The returned array preserves input order, removes nil entries and duplicates,
and contains only allowed subjects. It checks organization-wide, direct scoped
and inherited grants using the same separation-of-duties decision as `allow?`.
An ancestor's full-access flag alone does not grant access to a child; its role
must explicitly contain the requested key. `cascade: false` skips ancestor
grants while retaining organization-wide and direct grants.

An explicit `actor:` supplies the same real actor for every candidate's
separation-of-duties check; without it each candidate is evaluated as itself.
The method queries current grants on each call and keeps no authorization
snapshot. It does not add host account-status or workflow rules: filter those
candidates in the host policy. Collection questions still use `allow?` or
`scope_for`; they are not this method's input shape.

## Dev diagnostics

Three things this engine gets wrong **silently**, and silently in the bad
direction: what went wrong looks exactly like what going right looks like. Each
one now says so in the log.

| Flag | Fires when | Why you'd never notice otherwise |
|---|---|---|
| `warn_on_nil_sod_record` | An SoD action was **allowed** while the gate had no record, so the veto was skipped | A veto that never ran looks identical to a veto that passed |
| `warn_on_inert_scoped_grant` | Denied `no_grant`, the subject **holds a scoped grant** that would satisfy it, and the controller declares no `current_scope_record` | The 403 is byte-identical to "never granted", so you go audit the grants — which are fine — instead of the controller, which isn't |
| `warn_on_cross_controller_derivation` | Short-form `allowed_to?(:show, record)` derived a **different key** than the gate on this controller enforces | If you meant this controller's gate, the view and the gate disagree — and the symptom (a link that 403s, or a hidden one that works) shows up nowhere near the cause |

All three are **log-only** — no decision, exception, header, or audit row changes
because of them, in any environment — and all three default **on in development
and test, off in production**:

```ruby
config.warn_on_nil_sod_record = Rails.env.local?              # the defaults;
config.warn_on_inert_scoped_grant = Rails.env.local?          # override either
config.warn_on_cross_controller_derivation = Rails.env.local? # way
```

The last one is a **hint, not an accusation**, and says so: asking about a
different resource than the current controller handles derives a different key
too, and that is correct and common. Nothing at the call site distinguishes the
two, so it warns **once per site** and names both readings. The first two are
unambiguous.

The default is the point. These catch mistakes you make while *writing* the app,
which is exactly when dev/test is where you are — and a diagnostic that ships off
is one the people who need it never find. `warn_on_nil_sod_record` has worked
since v0.1 and defaulted off, which is how it helped nobody.

A fourth setting is a **mode, not a flag** — the opt-in `GatingTripwire`
already speaks; the question is how:

```ruby
config.gating_tripwire = Rails.env.local? ? :raise : :warn   # the default
```

`:raise` (dev/test) makes CI go red on an ungated action; `:warn` (elsewhere)
logs each ungated `controller#action` once, so a production host that included
the mixin gets an inventory instead of 500s. There is no `:off` — not including
the mixin is off.

Four loud-by-design behaviors. A controller excluded from the catalog can't be
granted, so gating it is a misconfiguration — Guard raises, names the matching
`excluded_controllers` pattern(s), and tells you to either stop excluding it or
`skip_before_action :current_scope_check!`. An unrouted `controller#action`
raises a different message (not-routed, not excluded). A `user_method` that the
controller doesn't respond to raises instead of silently turning every request
into a 403. And **granting a permission key that isn't in the catalog makes the
role invalid**, naming the key:

```ruby
role.permission_keys = %w[reports#aprove]   # typo
role.save   # => false
role.errors[:permission_keys]
# => ["not in the permission catalog: reports#aprove — check for typos, or use
#     assign_permission_keys(..., scrub: true) to drop stale keys deliberately"]
```

A grant that vanishes is the worst kind of bug this library can have: the role
looks right in the UI, the save succeeds, and the denial arrives later as an
unexplained 403. So a key the app doesn't route is an error, not a shrug — that
covers typos, programmatic grants of unrouted keys, and the never-routed
break-glass permission (which stays ungrantable; see #21).

There is one legitimate reason to drop a key silently: a controller was removed,
so a role still holds keys that no longer route. That is named at the call site
rather than assumed:

```ruby
role.assign_permission_keys(keys, scrub: true)   # stale keys dropped, no error
role.save!
role.permission_keys_change[:rejected]           # => ["gone#index"] — log it if you want
```

The diff is computed on save, so read it after. `scrub:` takes literal `true`
and nothing else — a stray truthy value must not be able to turn the strict
path off.

`scrub:` is deliberately not reachable from `permission_keys=`, so form params
and strong-params flows always take the strict path. The role editor is
unaffected: its grid is built from routed actions, so everything it submits is
already in the catalog, and a stale key is cleaned up transparently on save.
