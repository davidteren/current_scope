---
title: Upgrading
nav_order: 7
---

# Upgrading

The [CHANGELOG](https://github.com/davidteren/current_scope/blob/main/CHANGELOG.md)
is the canonical record of every release — read it top-down for the versions
you are crossing. Two changes deserve to be impossible to miss: one changes
your **security posture silently**, the other breaks programmatic callers
**loudly** (a 404):

## 0.1 → 0.2: separation of duties became opt-in (silent)

`config.sod_actions` now defaults to `[]` — empty means
[the SoD veto](separation-of-duties.md) never runs. A 0.1 host that relied
on the old default and never set `sod_actions` explicitly **loses the veto
on upgrade with no error and no warning**. If you want SoD, say so:

```ruby
config.sod_actions = %w[approve]
```

**Checklist if you might be affected**

1. Do any models define `current_scope_initiator`?
2. Is `config.sod_actions` still empty (or unset) after upgrade?
3. If both yes: re-set `sod_actions` and re-run an initiator-cannot-approve test.

Root-repo copy: [UPGRADING.md](https://github.com/davidteren/current_scope/blob/main/UPGRADING.md)
([#27](https://github.com/davidteren/current_scope/issues/27)).

## 0.2 → 0.3: management-UI route rename (loud — programmatic callers 404)

Org-wide role assignment is now `resources :role_assignments` (plural).
A host that POSTs `/current_scope/role_assignment` (singular) or uses the
old `role_assignment_path` / `remove_role_assignment_path` helpers gets a
404 on upgrade. The engine's own UI is unaffected — this bites only direct
path or helper callers. Details in the
[CHANGELOG errata](https://github.com/davidteren/current_scope/blob/main/CHANGELOG.md).

## Also in 0.2+

- Declared Rails floor is `>= 8.1` (the management UI relies on
  `params.expect` array semantics introduced in 8.1).
- `config.audit` became tri-state `false | true | :strict`.

## 0.3 → 0.4

Solid-solution Phase 1 (loud misconfig + audit honesty), denial ergonomics,
security checklist, docs site, migration toolkit. No intended host API break.
Boot **raises** if `sod_bypass_permission` is listed in `sod_actions` (#40).

## Silent SoD and advisory footguns (any version)

These are not version flips; they are permanent posture facts:

- **Collection actions in `sod_actions` are no-ops** for the veto (no record →
  no initiator). Do not list `approve_all`-style bulk actions and expect
  four-eyes. Filter per record with `allowed_to?(:approve, record)` inside the
  bulk action. Details:
  [Separation of duties](separation-of-duties.html#collection-actions-in-sod_actions-are-no-ops).
- **`full_access` holds every permission**, including break-glass
  `sod_bypass_permission` when break-glass is on. Prefer a narrow bypass role.
- **`allowed_to?` never consults the catalog.** Typo keys are silent false;
  a raw stale grant row can be silent true. The Guard is authoritative.
