---
title: "Two test processes, one database: the transient that was not a race"
module: test/support/support_table.rb
date: 2026-09-05
problem_type: workflow_issue
component: testing_framework
category: workflow-issues
severity: high
applies_when:
  - "Creating a table at load time in a test support file, outside any migration"
  - "Running a second test process in a checkout while one is already running (a system test file next to the unit suite, two terminals, an agent and a human)"
  - "Choosing between `force: true`, `if_not_exists: true`, or a drop at exit for a test-only table"
  - "Reading a test failure that reproduces once in ten runs and blames a table or a column"
  - "Deciding what a schema dumper should see in a test database"
symptoms:
  - "One run reports errors in tests that have nothing in common except a table; nine reruns are green"
  - "`no such table: current_scope_test_uuid_users` or `Could not find table` in the middle of a run"
  - "The count of failures depends on where the seed placed the tests, so it is 6 one day and 50 the next"
  - "Coverage drops under the CI floor on the red run, because the errored tests never ran their lines"
  - "A test-env `db:migrate` writes tables into the tracked `schema.rb` that no migration created"
  - "After a branch switch a support table keeps its old columns and the failure names the model, not the table"
root_cause: missing_workflow_step
resolution_type: test_fix
related_components:
  - testing_framework
  - "test/support/support_table.rb"
  - "test/support/uuid_user.rb"
  - "test/support/identity_user.rb"
  - "test/support_tables_test.rb"
  - "test/dummy/config/environments/test.rb"
  - "test/dummy/config/database.yml"
tags:
  - load-time-ddl
  - shared-test-database
  - sqlite
  - if-not-exists
  - schema-drift
  - schema-dumper
  - transient-failure
  - one-process-per-checkout
related_issues:
  - "#151 (merged as 820950d): introduced the load-time UUID subject table this entry is about"
  - "#202 (merged as a3695c2): the fix, `SupportTable.prepare`, and the one-process rule in AGENTS.md"
  - "#204 (open): the documented ceiling, a type-only or index-only change still needs `db:test:prepare`"
  - "docs/reviews/2026-09-04-validation-findings-pr197-201.md: finding 1, where the transient was chased"
---

# Two test processes, one database: the transient that was not a race

## Context

One `bin/rails test` run reported 6 errors. Nine reruns were green and the output was
not captured. It coincided with heavy concurrent headless-Chrome work, so the note
that recorded it said: real race in the suite, or contention, treat it as open.

It was neither. It was two Rails test processes sharing one database file and one
of them running destructive DDL at load time.

Three facts, each in one place in the tree:

**Every process shares one file.** `test/dummy/config/database.yml:21` gives the test
environment `storage/test.sqlite3`. Rails parallel workers suffix that name per
worker, but two top-level processes do not get a suffix. A system test file booting
while the unit suite runs opens the same file.

**Two support tables were built at load time with `force: true`.**
`test/support/uuid_user.rb` and `test/support/identity_user.rb` need real tables
that no migration creates (a string-keyed subject for #151, a name-plus-email subject
for #158). They are created when the file loads, before any test transaction opens,
because MySQL cannot run DDL inside a transaction. `force: true` drops whatever is
there first.

**Both were dropped at exit.** A `Minitest.after_run` block removed each table so that
a later test inspecting the table list would not see it.

Put together: the second process's boot dropped and recreated both tables under the
first process, and the first process's exit dropped them under the second. Every test
that touched either table after that point errored with `no such table`. How many
depends on when the drop landed relative to where the seed placed those tests, which
is why the original run saw 6 errors and nine reruns saw none.

Reproduced twice (two unit runs overlapping; the unit suite with a system test file
booting three seconds later): 1109 runs, 3 failures, 50 errors, line coverage 94.64%
against a 95% floor. The reverse order was green. Eight CPU burners and sixteen seeds
in isolation produced nothing, so contention was not the cause.

## Guidance

### Rule 1: load-time DDL on a shared database is never destructive on the happy path

A table a support file creates at load time is shared state, not fixture state. Every
process on that database sees the same table. `force: true` is a drop, and a drop in a
second process is a drop under the first.

The fix is not `if_not_exists: true` alone. That closes the drop and opens a trap: a
branch that changes the table's columns is ignored on every existing checkout until
someone runs `bin/rails db:test:prepare`, and the failure names the model, not the
table. Four reviews flagged it independently within the same day.

The middle path is `SupportTable.prepare` (`test/support/support_table.rb`): create
the table when missing, rebuild it only when its column names no longer match the
block, and never touch a table that matches. Two processes on a matching table cannot
pull it out from under each other. Two processes on a drifted table both rebuild, which
is the one-time cost of a branch switch and is what `drop_table(..., if_exists: true)`
tolerates.

### Rule 2: the drift signal comes from the block, not from a list beside it

The first version took a `columns:` manifest next to the block. A manifest that
drifts from the block never matches, so the table is dropped on every boot, which is
the exact race the helper exists to close, and no test would notice.

Derive the expected names from the same block that builds the table:

```ruby
wanted = conn.build_create_table_definition(name, **options, &block).columns.map(&:name).sort
if conn.table_exists?(name) && conn.columns(name).map(&:name).sort != wanted
  conn.drop_table(name, if_exists: true)
end
conn.create_table(name, if_not_exists: true, **options, &block)
```

`build_create_table_definition` is the public method `create_table` itself uses on
Rails 8.1, and it applies the primary key the same way, so `id: :string` yields
`["id", "name"]` on all three adapters. Column names are the signal; a type-only or
index-only change still needs `db:test:prepare`, and the file says so (#204).

### Rule 3: a table that persists must be hidden from the schema dumper

Once the tables survive the run, a test-env `db:migrate` (the command `AGENTS.md`
prescribes to build the engine's test database) dumps them into the tracked
`test/dummy/db/schema.rb`. The dummy test environment now tells the dumper to skip the
prefix:

```ruby
config.after_initialize do
  ActiveRecord::SchemaDumper.ignore_tables |= [ /\Acurrent_scope_test_/ ]
end
```

Pinned by a test that dumps the schema in-process and asserts no
`current_scope_test_` table appears, with a positive control that the table exists.

### Rule 4: test the helper on a probe table, never on the shared one

The first tests for the rebuild added a column to the real support table and reloaded
the support file. That is the same hazard in miniature: a half-failed rebuild would
have cascaded into every other test in the process. `test/support_tables_test.rb`
drives `SupportTable.prepare` on a throwaway `current_scope_test_probe` table that a
teardown drops. It is non-transactional, because the DDL is real and MySQL auto-commits
it.

### Rule 5: say the process rule out loud

No helper makes two processes on one SQLite file safe past the 5 s busy timeout.
`AGENTS.md` now says one test process per checkout, and that a worktree starts with
its own empty database (SQLite creates it on first run; MySQL and PostgreSQL need
`db:create db:migrate` there first). A per-process database name in `database.yml` was
tried and does not work: `rails/test_help` prepares the schema in a child process with
its own PID, so the parent sees an empty database and "Migrations are pending".

## Why This Matters

A transient that reproduces one run in ten is the most expensive class of failure a
suite can have. It is rerun until green, which trains everyone to rerun, and the day
it fires on a release gate nobody believes it. This one was written down as "may be a
real race in the suite; may be contention", which is where it would have stayed.

The cause was deterministic and the reproduction took one command. What hid it was
the assumption that a test process owns its database. On this repo it does not, and
the two files that assumed otherwise had been that way since #151.

## When to Apply

- Any `create_table`, `drop_table`, or raw DDL outside `db/migrate`: it must be
  idempotent, non-destructive when the table already matches, and ignored by the
  schema dumper.
- Any test that changes a table other tests read: drive a probe table instead.
- Any transient blamed on "concurrency" or "contention": run two processes on
  purpose before believing it. Load alone did not reproduce this; overlap did every
  time.
- Any local reproduction attempt of a CI-only failure: CI always starts from
  `db:test:prepare`, so the stale-table shape only ever shows locally.

## Examples

### Example 1: the shape of the red run

```
1109 runs, 3669 assertions, 3 failures, 50 errors, 0 skips
ActiveRecord::StatementInvalid: SQLite3::SQLException: no such table: current_scope_test_uuid_users
ActiveRecord::StatementInvalid: Could not find table 'current_scope_test_identity_users'
```

The three failures were tests expecting `CurrentScope::IdentitySetup::Halt` and
getting `StatementInvalid`. The second process reported one
`SQLite3::BusyException: database is locked` where the 5 s timeout expired while the
full run held the write lock. That last one is the residual the process rule covers.

### Example 2: the manifest that would have dropped the table every boot

```ruby
# before
SupportTable.ensure(UuidUser.table_name, columns: %w[id name], id: :string) { |t| t.string :name }
# after
SupportTable.prepare(UuidUser.table_name, id: :string) { |t| t.string :name }
```

Add `t.string :email` to the block and forget `columns:`, and the old version rebuilt
the table on every boot with no test going red. The new version cannot disagree with
itself.

### Example 3: the mutation that proves the rebuild

Replace `conn.drop_table(name, if_exists: true)` with `nil` and run
`test/support_tables_test.rb`: the drifted-column and renamed-column cases go red, the
matching-table case stays green. That pair is the whole contract.

## Related

- `docs/solutions/workflow-issues/simplecov-reports-a-number-that-is-quietly-wrong.md`:
  the same genre, a tool with one job printing a wrong number under a green suite.
- `docs/solutions/workflow-issues/the-exit-condition-nobody-can-reach.md`: Rule 2
  there, assert the question your change controls, is why the rebuild is pinned by a
  mutation and not by reading the config value back.
- `docs/reviews/2026-09-04-validation-findings-pr197-201.md`: finding 1, the chase.
