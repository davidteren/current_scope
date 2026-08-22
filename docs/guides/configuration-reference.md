# Configuration reference

> See also: [Concepts & glossary](concepts-and-glossary.md).

## Configuration

Everything lives in `config/initializers/current_scope.rb` (created by the
install generator): the `user_method`, the `subject_class`, `sod_actions`,
`excluded_controllers` (keep infrastructure out of the grid), and
`parent_controller` (what the management UI inherits from). The three
impersonation knobs — `actor_method`, `allow_mutations_while_impersonating`,
and `sod_identity` — are grouped in their own block and covered under
[Impersonation](impersonation.md); they layer in that order, so
`sod_identity` is only observable once a mutation is allowed past the read-only
gate.

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
never find. Put a plain unique index on exactly the identity columns and the boot
check answers from the index, with no query at all. Without one it is a
grouping query over the subject table. To list every duplicate, run
`bin/rails current_scope:identity:check`. Guided attach:
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
unaudited change (the mutation rolls back). Direct `RoleAssignment` /
`ScopedRoleAssignment` writes and the test helpers (`grant_role!` /
`grant_scoped_role!`) are **not** recorded — use `grant!` for bootstrap
paths that need a ledger trail. UI events stamp `request_id` from
`ActionDispatch::RequestId` via the Context hook.

> **Note on the `!`:** despite the bang, `Event.record!` only guarantees
> raise-on-failure under `:strict` (and for a missing actor). In the default
> `true` mode a missing events table is a warn-once no-op, and under `false`
> every call silently returns `nil` — so a mutation-wrapping transaction does
> **not** roll back on a failed audit write unless you opt into `:strict`.

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
