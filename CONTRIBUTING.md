# Contributing

## Development setup

Install and activate the Ruby version in `.ruby-version` (currently 3.4.9),
using your preferred Ruby version manager. CI reads the same file. Install
Chrome or Chromium for the browser tests; set `BROWSER_PATH` to its executable
if Ferrum cannot locate it automatically. Native gems need a C compiler and
the OpenSSL development headers. Building Ruby itself also needs its normal
build prerequisites, including libyaml.

From this checkout, run:

```bash
bin/setup
```

This installs the Bundler version recorded in `Gemfile.lock` if necessary,
installs the locked dependencies, and prepares the dummy app's SQLite test
database from the committed schema. It does not start a server or rewrite
the lockfile or schema. It is safe to rerun. Keep `DATABASE_URL` unset for
this default setup; use `bin/db` below for the server adapters.

If the compact-index host `index.rubygems.org` is unavailable but
`rubygems.org` is allowed, use `bin/setup --full-index`. Bundler must already
be installed in that case because RubyGems' Bundler installer also uses the
index host. TLS and artifact verification remain enabled. `BUNDLE_PATH` and
`BUNDLE_USER_HOME` can point to writable locations on restricted machines.

### Cloud environments

The repository owns the Ruby pin, `bin/setup`, and the test commands. The
cloud environment owns machine provisioning, network policy, credentials,
and the filesystem snapshot. Keep machine-specific tool installation and
paths outside the repository. Its install script should activate Ruby and
then run `bin/setup` in the checkout (with `--full-index` when needed).

Save startup instructions that activate Ruby and any local Bundler settings
in each new task. Use the existing checkout: cloud tasks are already isolated,
so a worktree is unnecessary unless explicitly requested. SQLite needs no
service; browser tests start and stop their own HTTP servers. For adapter
work, run `bin/db up` again because running containers and other processes
must not be assumed to survive publication.

Saving environment settings stores a draft. Publishing creates an active
configuration and a filesystem snapshot for future tasks; it does not deploy
the application or commit changes to Git. Environment snapshots, installed
gems, credentials, and machine-specific paths do not belong in this repo.

## Test suite

From the engine root:

```bash
bin/setup
SIMPLECOV_COMMAND_NAME=unit bin/rails test
SIMPLECOV_COMMAND_NAME=system bin/rails test:system
```

The engine's `bin/rails` runs one command per invocation. Split prepare and test
the way CI does.

Coverage is on by default (`simplecov`). Set `COVERAGE=0` to skip.

The distinct command names above merge unit and system coverage, as CI does.
Without them, the second run replaces the first. Run only one test process
at a time in a checkout: they share the same SQLite database.

The documentation browser tests serve static fixtures over a temporary
loopback HTTP port and permit browser requests only to that server. They
work with managed browsers that disallow `file://`, without changing browser
policy or requiring public network access. Each test closes its server and
browser; localStorage stays on the same origin across navigations within a
test and is isolated between browser instances.

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

Every PR runs [Mutineer](https://github.com/davidteren/mutineer) in
`.github/workflows/mutation.yml` (no path filter — the check is meant to be
required, so it must always report). The job mutates only lines changed since
the PR base, runs the covering unit/integration tests, and fails when the
score drops below 80% (or when the run cannot score a meaningful set of
mutants). A docs-only or config-only diff schedules zero mutants and the
job still succeeds.

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
`--since` PRs do not need parallel workers; turning daemon on is
[#227](https://github.com/davidteren/current_scope/issues/227). Always set
`COVERAGE=0`: `test_helper` would otherwise start SimpleCov, which fights
Mutineer's coverage map and, under `CI=1`, applies the 95/80 floor to a
subset run.

`bin/mutineer-test-files` is the explicit `--test` list. The engine's tests
are not 1:1 with sources (`lib/current_scope/resolver.rb` is covered by
`test/resolver_test.rb`), so Mutineer's convention auto-pair would skip most
of the authorization core. System tests, generator tests, docs-site pins,
gemspec/coverage/upgrading wiring tests, and this gate's own config pin are
omitted: they cannot kill mutants in `lib/current_scope` or `app/`, and
generator tests fail under Mutineer's `--rails` boot.

Do not pass `--since none` on a PR — a full-tree run is hours. When you want
a committed `.mutineer/baseline.json` later, generate it on `main` from a
full scan and keep the file; `.mutineer/*` is gitignored except that path.

The check name is `mutineer`. Require it in branch protection (Settings →
Branches) if the API cannot add it — this repo's token often cannot.

The normal mutation gate covers engine runtime code. For changes to the
documentation HTTP/browser harness, use the focused check below. It loads
the helper before surgical mutation and tests real HTTP navigation, request
isolation, and server shutdown. Keep this run serial too:

```bash
RAILS_ENV=test COVERAGE=0 bundle exec mutineer run \
  test/system/support/headless_chrome.rb \
  --boot test/mutineer_docs_boot.rb \
  --test test/system/docs_site_server_test.rb \
  --test test/system/docs_site_ai_test.rb \
  --since origin/main --timeout 30 \
  --cache-dir tmp/mutineer-docs \
  --format json --output tmp/mutineer-docs-report.json
```

The lockfile records Mutineer 1.6.0. `bundle exec mutineer --version` confirms
which release a run uses. A diff with no engine-source changes produces no
mutants in the normal gate; that is not evidence of test strength. Read the
focused report's scored, surviving, and unscored outcomes separately.

## Style

RuboCop omakase: `bin/rubocop` clean before commit.

## Workflow

See [AGENTS.md](AGENTS.md) for hard rules (fail-closed resolver, PRs always,
pre-PR review gate) and [STATUS.md](STATUS.md) for current phase notes.
