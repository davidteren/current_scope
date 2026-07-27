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

## Related silent-security docs (not version-specific)

- Collection actions in `sod_actions` are **no-ops** for the veto (no record →
  no initiator). Bulk self-approval needs per-record `allowed_to?` in the action
  body. See [Separation of duties](docs/site/separation-of-duties.md).
- Advisory `allowed_to?` never consults the permission catalog (typos are silent
  false; a stale grant row can be silent true). The Guard is authoritative.
  See README "Checking permissions".

Tracked originally as #27, #29, #36.
