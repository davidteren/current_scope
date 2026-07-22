---
title: Quickstart
nav_order: 2
---

# Quickstart

> **Not production-ready yet.** CurrentScope is ready for experimentation and
> spiking — kick the tyres, build a spike, tell us what breaks. Don't put it
> in front of real users yet. Open work, including security-relevant items,
> is tracked in the
> [issue tracker](https://github.com/davidteren/current_scope/issues).

## 1. Add the gem and install

```ruby
# Gemfile
gem "current_scope"
```

```bash
bin/rails generate current_scope:install
bin/rails current_scope:install:migrations && bin/rails db:migrate
```

## 2. Include the concerns

`Context` populates the ambient subject from your authentication; `Guard`
gates every action behind its own `controller#action` permission:

```ruby
class ApplicationController < ActionController::Base
  include CurrentScope::Context   # sets CurrentScope::Current.user from current_user
  include CurrentScope::Guard     # fail-closed gate on every action
end
```

Your authentication must run **before** these concerns do — `Context` reads
`current_user` when its callback fires. If your auth is set up in a concern
or callback registered *after* these includes, the gate runs first, sees no
subject, and denies. The
[adoption guide](https://github.com/davidteren/current_scope/blob/main/docs/guides/adopting-in-an-existing-app.md)
covers callback ordering against Devise and friends.

## 3. Skip the gate where authorization doesn't apply

**Do not skip this step.** The gate is fail-closed and covers *everything*,
including sign-in — mount it without this and nobody can log in:

```ruby
class SessionsController < ApplicationController
  skip_before_action :current_scope_check!
end
```

A skipped controller is unprotected by the permission gate — supply your own
authorization where that matters, and read the
[security checklist](security-checklist.md) before shipping.

## 4. Existing app? Run report mode first

The fail-closed gate denies everything until grants exist. On a greenfield
app that's invisible. On an app with users and traffic, cutting over blind
means red suites and 403s. Report mode logs what it *would* have denied and
lets requests through:

```ruby
CurrentScope.configure do |config|
  config.enforcement = :report   # :enforce (default) | :report
end
```

Exercise the app or run your suite, then read the gaps back out — this is
your grant-seeding worklist:

```bash
bin/rails current_scope:report
```

Seed the roles it names, re-exercise the app, and flip back to `:enforce`
once newly exercised requests stop adding `access.would_deny` rows (the
report reads the append-only ledger, so historical rows do not clear) and
any `access.sod_blind_spot` entries are resolved.
Report mode is an adoption ramp, not an off switch: the SoD veto, the
management console, and the impersonation gate all still refuse. Retrofitting
a real app? There is a
[full adoption guide](https://github.com/davidteren/current_scope/blob/main/docs/guides/adopting-in-an-existing-app.md)
— callback ordering vs. your authentication, the Devise recipe, and a
rollout ladder.

## 5. Bootstrap the first admin

The management UI only admits full-access subjects, so the first grant can't
happen in the UI:

```bash
# The id must exist on your configured subject_class ("User" by default).
bin/rails current_scope:grant SUBJECT_ID=<your-user-id>
```

or in `db/seeds.rb`:

```ruby
# Creates the default Owner (full_access) + Member roles if missing, then
# grants Owner. Member starts with zero permissions until you edit it.
CurrentScope.grant!(User.first)
```

## 6. Manage everything at `/current_scope`

The role grid, org-wide assignments, and scoped grants — all editable data,
no deploys.

## Where next

- [Concepts](concepts.md) — the resolver order and the ideas behind it.
- [Separation of duties](separation-of-duties.md) — the anti-fraud veto
  (opt-in; off until you enable it).
- [Security checklist](security-checklist.md) — read before shipping.
- [Configuration](configuration.md) — every knob, with defaults.
- [For AI agents](ai-agents.md) — copy-paste prompts that encode the
  foot-guns.
