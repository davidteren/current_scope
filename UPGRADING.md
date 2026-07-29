# Upgrading CurrentScope

Read the [CHANGELOG](CHANGELOG.md) for every version you cross. This file calls
out the silent posture changes that a changelog line is easy to miss.

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

## 0.4 → 0.5: a mis-declared `current_scope_parent` now fails the deploy (#139)

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
request path re-runs this check. If you deploy with `eager_load = false`, or
keep declaring models off the eager-load surface, this check does **not** fully
protect you. That is the same partial-coverage bargain the permission catalog
makes, and it is stated rather than implied.

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
