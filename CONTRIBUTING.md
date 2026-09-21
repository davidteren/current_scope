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

CI enforces `minimum_coverage line: 95, branch: 80`. A failure means code landed
without tests. Open the `coverage` artifact CI uploads, or local
`coverage/index.html`, and cover the red lines. Reproduce locally by putting
`CI=1` in front of the two `SIMPLECOV_COMMAND_NAME` commands above, after
deleting `coverage/`. Do not lower the floor to make a PR pass.

## Running against PostgreSQL and MySQL

The suite defaults to SQLite, which coerces comparisons the other two refuse — a
SQLite-only suite is how the #151 privilege escalation reached three releases. CI
runs all three, and so should you before opening a PR that touches queries or the
schema.

```bash
bin/db up            # postgres + mysql containers (Docker/OrbStack)
bin/db test          # the unit suite against all three
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

Then check the diff shows only your change. A `schema.rb` dumped from a non-MySQL
adapter carries no MySQL collation, which is why `bin/db` and CI apply the #151
widening migration on top of the loaded schema rather than trusting the dump
alone. (A dump taken from MySQL does carry one; see the 0.4 to 0.5 section of
[UPGRADING.md](UPGRADING.md).)

## Regenerating screenshots

README and docs-site screenshots come from the system suite:

```bash
CAPTURE_SCREENSHOTS=1 RAILS_ENV=test bin/rails test test/system/screenshots_test.rb
```

## Mutation testing

PRs that touch engine Ruby (`lib/`, `app/`) or the suite are mutation-tested
by [Mutineer](https://github.com/davidteren/mutineer) in
`.github/workflows/mutation.yml`. The job mutates only lines changed since the
PR base, runs the covering unit/integration tests, and fails when the score
drops below 80% (or when the run cannot score a meaningful set of mutants).

That is a different question from SimpleCov: coverage says the line ran;
mutation testing asks whether any assertion would notice if it lied.

```bash
RAILS_ENV=test bin/rails db:test:prepare
RAILS_ENV=test COVERAGE=0 bundle exec mutineer run \
  lib/current_scope.rb lib/current_scope app \
  $(bin/mutineer-test-files | sed 's/^/--test /') \
  --since origin/main
```

`.mutineer.yml` supplies `--rails`, `--boot test/mutineer_boot.rb` (dummy app
plus `test/` on `$LOAD_PATH`, so `require "test_helper"` works), and the 80%
floor. Runs are serial (`--jobs 1`): Mutineer's `--daemon` worker DBs load
`db/schema.rb` from the project root, but this engine's schema is
`test/dummy/db/schema.rb`, so those copies would be empty. Incremental
`--since` PRs do not need parallel workers. Always set `COVERAGE=0`:
`test_helper` would otherwise start SimpleCov, which fights Mutineer's
coverage map and, under `CI=1`, applies the 95/80 floor to a subset run.

`bin/mutineer-test-files` is the explicit `--test` list. The engine's tests
are not 1:1 with sources (`lib/current_scope/resolver.rb` is covered by
`test/resolver_test.rb`), so Mutineer's convention auto-pair would skip most
of the authorization core. System tests are omitted on purpose.

Do not pass `--since none` on a PR — a full-tree run is hours. When you want
a committed `.mutineer/baseline.json` later, generate it on `main` from a
full scan and keep the file; `.mutineer/*` is gitignored except that path.

The check name is `mutineer`. Require it in branch protection (Settings →
Branches) if the API cannot add it — this repo's token often cannot.

## Style

RuboCop omakase: `bin/rubocop` clean before commit.

## Workflow

See [AGENTS.md](AGENTS.md) for hard rules (fail-closed resolver, PRs always,
pre-PR review gate) and [STATUS.md](STATUS.md) for current phase notes.
