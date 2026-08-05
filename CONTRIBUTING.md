# Contributing

## Test suite

From the engine root:

```bash
RAILS_ENV=test bundle exec rake db:create db:migrate
bin/rails test
bin/rails test:system
```

The engine's `bin/rails` runs one command per invocation. Split prepare and test
the way CI does.

Coverage is on by default (`simplecov`). Set `COVERAGE=0` to skip.

The two runs above share one result name, so the second replaces the first. Name
them the way CI does to get the combined figure:

```bash
SIMPLECOV_COMMAND_NAME=unit bin/rails test
SIMPLECOV_COMMAND_NAME=system bin/rails test:system
```

Delete `coverage/` before the **first** of those two commands, never between them:
the second run merges into the first one's result. Results older than ten minutes
are dropped from the merge with a warning; fresher stale ones merge silently.

The bootstrap (`test/coverage_setup.rb`) has to load before the engine does, or
Ruby's `Coverage` cannot instrument `lib/`. It aborts the run if it ever starts
too late, rather than reporting a figure that is far too low.

## Running against PostgreSQL and MySQL

The suite defaults to SQLite, which coerces comparisons the other two refuse — a
SQLite-only suite is how the #151 privilege escalation reached three releases. CI
runs all three, and so should you before opening a PR that touches queries or the
schema.

```bash
bin/db up            # postgres + mysql containers (Docker/OrbStack)
bin/db test          # the suite against all three
bin/db test postgres # or just one
bin/db down
```

Containers use non-default ports (55432, 33306) so they cannot collide with a
database you already run.

### Do not regenerate `test/dummy/db/schema.rb` on SQLite

The committed dump says `t.bigint` for every foreign key, because that is what
`t.references` really creates on PostgreSQL and MySQL. SQLite's dumper writes
`t.integer` for the same column. The difference is not cosmetic: MySQL refuses a
foreign key from an `INT` column to a `BIGINT` primary key, so a schema
regenerated on SQLite makes the MySQL leg fail to load at all.

If you add a migration, dump the schema from a server adapter:

```bash
DATABASE_URL="$(bin/db url postgres)" RAILS_ENV=test bin/rails db:migrate
```

Then check the diff shows only your change. `schema.rb` also cannot carry a MySQL
collation, which is why `bin/db` and CI apply the #151 widening migration on top
of the loaded schema rather than trusting the dump alone.

## Regenerating screenshots

README and docs-site screenshots come from the system suite:

```bash
CAPTURE_SCREENSHOTS=1 RAILS_ENV=test bin/rails test test/system/screenshots_test.rb
```

## Style

RuboCop omakase: `bin/rubocop` clean before commit.

## Workflow

See [AGENTS.md](AGENTS.md) for hard rules (fail-closed resolver, PRs always,
pre-PR review gate) and [STATUS.md](STATUS.md) for current phase notes.
