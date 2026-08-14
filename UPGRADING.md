# Upgrading CurrentScope

Read the [CHANGELOG](CHANGELOG.md) for every version you cross. This file calls
out the silent posture changes that a changelog line is easy to miss.

## Unreleased: custom polymorphic tokens are first-class (#155)

Stored grant types use `polymorphic_name`, not `base_class.name`. Default
models do not change. If a model overrides `polymorphic_name` (or shortens it
with `store_full_class_name = false`):

- Collection lists and record-less write checks now see those grants.
- Two classes must not share a token. Rebuild raises `ConfigurationError`.
  That includes a shortened name that matches another loaded class (for
  example `Admin::User` storing `"User"` next to `::User`). STI siblings
  that store their base name are not a clash.
- Optional: `config.polymorphic_class_names = { "token_docs" => "TokenDocument" }`
  for a token that must resolve before the model is loaded. After a namespaced
  model with `store_full_class_name = false` is loaded, a shortened token that
  does not constantize is registered automatically. The class must actually
  store that token. A leftover name mapped onto a live class is refused, so a
  stale grant stays inert.

  Auto-registration only sees models loaded when the registry rebuilds. Under
  `eager_load` (production) that is every model; in development a custom-token
  model autoloaded after boot is not reverse-resolvable until the next reload.
  Map any token that must resolve regardless of load timing.
- A token is the stored grant identity. If you retire a model and later reuse
  its `polymorphic_name` token for a different class, existing grants rebind to
  the new class — treat a token rename or reuse as a data migration.

An unmapped custom token stays inert. That is not a permit.

## 0.1 → 0.2: SoD became opt-in (silent fail-open if you relied on defaults)

**If you used separation of duties on 0.1 defaults, re-add:**

```ruby
# config/initializers/current_scope.rb
config.sod_actions = %w[approve]   # or whatever actions you SoD-gate
```

### What changed

`config.sod_actions` default flipped from `%w[approve]` to `[]`. Empty means
the SoD veto never runs. A 0.1 host that never set `sod_actions` and relied on
the old default **loses four-eyes on upgrade with no error and no warning** —
self-approvals that used to 403 start succeeding.

That is exactly the silent fail-open class this gem otherwise crusades against.
It is documented here and on the
[docs site Upgrading page](https://davidteren.github.io/current_scope/upgrading.html)
because the earliest adopters are the ones hit.

### How to check

1. Did you **intend** to keep separation of duties after upgrade?
2. If yes: search for `current_scope_initiator` on models. If any model defines
   it and `sod_actions` is empty, re-set `sod_actions` and re-run the
   initiator-cannot-approve test from the
   [SoD guide](https://davidteren.github.io/current_scope/separation-of-duties.html).
3. If no (you deliberately left SoD off): leave `sod_actions` empty. Initiator
   hooks alone are not proof of a mistake.

Also in 0.2: declared Rails floor `>= 8.1` (management UI uses `params.expect`).

## 0.2 → 0.3: management route rename (loud — 404)

Org-wide role assignment routes are plural: `resources :role_assignments`.
Direct POSTs to the singular path **404**. Stale helper calls
(`role_assignment_path`) can fail earlier with an **undefined helper** /
URL-generation error. Engine UI is fine; only programmatic callers need a
path update. See CHANGELOG errata.

## 0.3 → 0.4

Solid-solution Phase 1, denial ergonomics, security checklist, docs site, and
the migration toolkit. No intended host API break. Boot now **raises** if
`sod_bypass_permission` is listed in `sod_actions` (#40) instead of 500ing on
the first real bypass.

## 0.4 → 0.5: run the migrations, or the engine will not boot (security, #151)

**This release fixes a privilege escalation. If your subject or scoped-resource
models use UUID or other string primary keys, you were affected on 0.2, 0.3 and
0.4.**

Grant ids lived in integer columns, so a non-numeric key was cast on write:
`"7f00aaaa-…"` and `"7f00bbbb-…"` both stored as `7`, and a key starting with a
letter stored as `0`. Two subjects became one, and one inherited the other's
org-wide role, `full_access` included. Nothing failed; the association still
resolved, to the wrong record.

### What you must do

```bash
bin/rails current_scope:install:migrations
bin/rails db:migrate
```

The columns become `varchar(64)`, so integer, UUID and ULID keys are all stored
whole. **The engine raises at boot until this migration has run** — a gem upgrade
alone would leave the escalation in place while every code path looked correct.

The migration rewrites both grant tables under an exclusive lock (PostgreSQL
`ACCESS EXCLUSIVE`, MySQL `ALGORITHM=COPY`). Grant tables are normally small, so
this is quick; if yours is large, schedule it like any other table rewrite, or
run it through your usual online-DDL tool.

Database, installer and `assets:` tasks are exempt from the boot refusal, so the
repair and your asset build still run on an unmigrated host. Everything that
serves traffic or runs your code — server, console, `runner`, and `db:seed` —
is refused. If some other build step must boot before the migration can run, set
`CURRENT_SCOPE_SKIP_SCHEMA_CHECK=1` **for that one command** (the literal string
`1`; any other value is ignored and logged). Setting it for a process that serves
traffic turns the guard off and puts the escalation back.

### If your database was built from `schema.rb`

New apps, CI, and fresh checkouts load `schema.rb` rather than running
migrations — and that marks every migration as already applied, so `db:migrate`
finds nothing pending. `schema.rb` also cannot express a MySQL collation. On
MySQL that combination leaves the columns case-insensitive, the engine refusing
to boot, and `db:migrate` unable to help. Run the repair task instead:

```bash
bin/rails current_scope:repair_schema
```

It is idempotent and safe to re-run, and it is exempt from the boot refusal so
it works on a database the engine will not otherwise start against.

**On MySQL, run the repair before seeds that create grants.** `db:setup`,
`db:reset`, and `db:prepare` load `schema.rb` and then run your seeds in the same
process — and `schema.rb` cannot carry the binary collation, so the columns are
still case-insensitive when the seeds run. A seed that creates a grant is
refused (the write path re-checks the schema, on purpose — an unrepaired column
is the #151 collision). Run `bin/rails current_scope:repair_schema` after loading
the schema and before seeding grants, or keep grant-creating seeds out of the
one-shot rebuild. This is the guard working, not a bug: it fails closed rather
than seed collapsible grants.

On MySQL the columns are given a binary collation: `utf8mb4_0900_bin` where the
server offers it (8.0.17+), otherwise `utf8mb4_bin`. The server default is case-
and accent-insensitive, which would make `"ABC"` and `"abc"` — or `"jose"` and
`"josé"` — the same subject. `utf8mb4_0900_bin` is preferred because it is also
`NO PAD`, so `"abc"` and `"abc "` stay distinct too. A primary key is an
identifier, not prose.

Keys longer than 64 characters are rejected rather than truncated, because a
truncated key names the wrong record.

### Every host: grant ids now read back as strings

This part affects you **even if all your keys are integers**, because the column
type changed for everyone:

```ruby
grant = CurrentScope::RoleAssignment.find_by(subject: user)
grant.subject_id        # => "7"  (was 7)
grant.subject_id == user.id   # => false, and it used to be true
grant.subject_id.to_s == user.id.to_s  # => true
```

If your own code compares a grant id against a model id, compare `.to_s` on both
sides. The engine's own queries are unaffected: `where(subject: user)` and
`scope_for` cast for you.

A grant is also now refused at write time when the id is not a legal key for the
model it names — `resource_type: "Project"` with a UUID `resource_id`, say. Such
a row could never identify a real `Project`, and left alone the read path would
cast it back to a *different* project's id. If you build grants from parameters
or an import rather than from a located record, expect that validation to start
rejecting rows it previously accepted; those rows were never safe.

### Audit the rows you already have

**Widening the column does not repair rows already written.** Once `"7f00aaaa-…"`
was stored as `7`, the original value is gone. After migrating, those grants match
nobody, so they fail closed (access lost, not gained) and appear as inert grants.
They must be re-granted.

Every grant held on a type whose key is not an integer is suspect — not only the
ones now pointing at nothing. A collapsed value could also land ON a real record
(`"7f00…"` becomes `7`, and another record's key is `7`), which is the dangerous
case an orphan check misses:

```ruby
[[CurrentScope::RoleAssignment, %w[subject]],
 [CurrentScope::ScopedRoleAssignment, %w[subject resource]]].each do |model, sides|
  sides.each do |side|
    model.distinct.pluck(:"#{side}_type").compact.each do |type|
      # polymorphic_class_for, not safe_constantize: the column stores a Rails
      # TOKEN, which a custom polymorphic_name or store_full_class_name = false
      # can shorten.
      klass = begin
        ActiveRecord::Base.polymorphic_class_for(type)
      rescue NameError
        next
      end
      key = klass.primary_key
      next if key.is_a?(String) && klass.type_for_attribute(key).type == :integer

      count = model.where("#{side}_type" => type).count
      puts "RE-GRANT: #{count} #{model.name} row(s) with #{side}_type=#{type} (#{klass.name} keys on #{key.inspect})"
    end
  end
end
```

## 0.4 → 0.5, separately: a mis-declared `current_scope_parent` now fails the deploy (#139)

This is an unrelated change that lands in the same release. It is not part of the
#151 fix above and needs its own attention.

**If your app boots today and stops booting after upgrading**, you have a
`current_scope_parent` declared on a `belongs_to` with a custom `primary_key:`.
That was already broken; it was just never checked. The error names the model
and the association.

```ruby
# The shape that now refuses to boot:
class Report < ApplicationRecord
  belongs_to :project, primary_key: :slug, foreign_key: :project_slug
  current_scope_parent :project        # <- refused
end
```

### What changed

The check itself is not new — `ParentChain.validate_declarations!` has always
refused this. What changed is **when it runs**. It used to run only from
`to_prepare`, which railties executes *before* eager loading, so it saw only the
models something else had already loaded. In production that is close to none,
so the check could be skipped entirely for the model that needed it. It now also
runs after eager loading, where the registry is complete.

**Where it still does not look.** That second pass is gated on
`config.eager_load`, because with eager loading off it would autoload reloadable
models during initialization — which Rails warns against, and which pins
constants the first reload then makes stale. So:

| `config.eager_load` | Coverage |
|---|---|
| `true` (production, staging by default) | every declaring model that was **eager-loaded** (and thus registered) is validated at boot |
| `false` (development, test, and any environment that turns it off) | only models already loaded when `to_prepare` runs — which grows across reloads, but is never a guarantee |

Models excluded from eager load (`do_not_eager_load`, paths outside
`eager_load_paths`) still register only when first loaded, and nothing on the
request path re-runs this check. The same is true of a model first loaded from
a host `after_initialize` block that runs *after* this engine's pass (callback
order among `after_initialize` blocks is registration order, not "after every
host hook").

When the pass *does* run, `validate_key!` resolves `reflection.klass` on each
declaring model's parent association. A parent type kept off the eager-load
surface can still be autoloaded at that moment so the primary-key comparison
can run. That is intentional (skipping it would leave the dangerous chain
unchecked) and only bites hosts with a partial eager-load surface.

If you deploy with `eager_load = false`, or keep declaring models (or their
parent types) off the eager-load surface, this check does **not** fully protect
you without that residual load. That is the same partial-coverage bargain the
permission catalog makes, and it is stated rather than implied.

### Why it is worth a broken deploy

An unvalidated chain of this shape does not fail safely. Both the collection
query (`scope_for`) and the unloaded member walk (`load_parent`) key the parent
on its **primary key**, so they compare values from two different columns. The
result is wrong in both directions on both surfaces:

- records the grant *should* reach are **not** returned / denied, and
- unrelated records **are** returned / allowed whenever their foreign-key value
  collides with a granted parent's id — with a numeric custom key, a dense
  collision space.

That second half is a subject seeing (and opening) records nobody granted them.
Failing the deploy is the correct outcome; the alternative is continuing to
serve wrong authorization answers quietly.

### If you need to ship right now

Remove the `current_scope_parent` declaration to restore the previous
behaviour (flat matching, no chain), fix the association to key on the primary
key, and re-declare.

## Related silent-security docs (not version-specific)

- Collection actions in `sod_actions` are **no-ops** for the veto (no record →
  no initiator). Bulk self-approval needs per-record `allowed_to?` in the action
  body. See [Separation of duties](docs/site/separation-of-duties.md).
- Advisory `allowed_to?` never consults the permission catalog (typos are silent
  false; a stale grant row can be silent true). The Guard is authoritative.
  See README "Checking permissions".

Tracked originally as #27, #29, #36.
