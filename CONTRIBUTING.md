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
