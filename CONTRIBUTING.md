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

The bootstrap (`test/coverage_setup.rb`) has to load before the engine does, or
Ruby's `Coverage` cannot instrument `lib/`. It aborts the run if it ever starts
too late, rather than reporting a figure that is far too low.

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
