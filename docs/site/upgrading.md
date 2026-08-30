---
title: Upgrading
nav_order: 7
---

# Upgrading

The [CHANGELOG](https://github.com/davidteren/current_scope/blob/main/CHANGELOG.md)
is the canonical record of every release — read it top-down for the versions
you are crossing. Two changes deserve to be impossible to miss: one changes
your **security posture silently**, the other breaks programmatic callers
**loudly** (a 404). Unreleased: custom `polymorphic_name` tokens are matched
on lists and reverse-resolved through a closed map (see `UPGRADING.md`).

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

## 0.4 → 0.5: run the migration, or the engine will not boot (security, #151)

**This release fixes a privilege escalation.** Grant ids were stored in integer
columns, so a model with a UUID (or any non-numeric) primary key had its key
truncated on write: `"7f00aaaa-…"` and `"7f00bbbb-…"` both became `7`. Two
subjects became one identity, and one inherited the other's org-wide role —
`full_access` included. If your subject or scoped-resource models use string
primary keys, you were affected on 0.2, 0.3 and 0.4.

```bash
bin/rails current_scope:install:migrations
bin/rails db:migrate
bin/rails db:test:prepare
```

The test database is a separate database with the same guard on it, so
`bin/rails db:test:prepare` is part of the upgrade, not an afterthought: skip it
and your next test run aborts at boot. That boot error names the database it
judged and prefixes its command with `RAILS_ENV=test`, so it points at the
database that failed rather than the one you have just migrated. On MySQL, run `RAILS_ENV=test bin/rails
current_scope:repair_schema` as well: `db:test:prepare` builds the test database
from `schema.rb`, which may not carry the binary collation, so the guard refuses
there even though development is now correct.

The engine **raises at boot until that migration has run**, because a gem
upgrade alone would leave the escalation in place while every code path looked
correct. Database, installer and `assets:` tasks are exempt so the repair and
your asset build still work; anything that serves traffic or runs your code is
refused.

**If your database was built from `schema.rb`** — a new app, CI, a fresh
checkout — run this instead. `schema.rb` may not carry a MySQL collation, and
loading a schema marks every migration as already applied, so `db:migrate` has
nothing to do:

```bash
bin/rails current_scope:repair_schema
bin/rails db:test:prepare
```

Your test database is a separate database with the same guard on it, and
`db:test:prepare` reloads the same `schema.rb`. On MySQL, repair it too, or the
next `bin/rails test` still aborts at boot:

```bash
RAILS_ENV=test bin/rails current_scope:repair_schema
```

On MySQL, run that repair **before** any seeds that create grants:
`db:setup`/`db:reset`/`db:prepare` load `schema.rb` (which may leave the columns
case-insensitive) and seed in the same process, so a grant-creating seed is
refused until the collation is repaired. That refusal is the guard working, not a
bug. See `UPGRADING.md`.

Two things to know before you upgrade:

- **Rows written earlier are not repaired.** Once `"7f00aaaa-…"` was stored as
  `7` the original value is gone. Those grants match nobody afterwards, so they
  fail closed and must be re-granted. `UPGRADING.md` carries an audit query that
  lists them, including the dangerous case where a truncated value landed on a
  real record.
- **Grant ids now read back as strings for every host**, integer keys included:
  `grant.subject_id == user.id` is now `false` where it used to be `true`.
  Compare `.to_s` on both sides in your own code. This breaks host code
  silently, with no exception and no log line: a tuple comparison against live
  ids can delete every grant, and a hash keyed by `subject_id` misses every
  lookup. `UPGRADING.md` lists the shapes to look for.

Full detail, including the MySQL collation and the 64-character limit, is in
[UPGRADING.md](https://github.com/davidteren/current_scope/blob/main/UPGRADING.md).

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
