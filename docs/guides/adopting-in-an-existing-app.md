# Adopting CurrentScope in an existing app

The quickstart in the README assumes a fresh app. This guide is for the harder,
more common case: an app that already has users, authentication, controllers, and
traffic — where "add the gem and go" isn't an option, because the gate is
fail-closed and nothing is granted yet.

Everything here is about one question: **how do you turn this on without breaking
things you can't afford to break?**

---

## Start in report mode. Don't cut over blind.

This is the whole guide in one line. Everything else is detail.

The gate denies anything not granted. On day one of a retrofit, *nothing* is
granted — so mounting it means your controller suite goes red and your users get
403s. Nothing is misconfigured when that happens; it's the gate working on an app
nobody has granted anything in yet.

```ruby
# config/initializers/current_scope.rb
CurrentScope.configure do |config|
  config.enforcement = :report
end
```

Report mode makes the gate **observe instead of refuse**: it logs what it *would*
have denied, records it, and lets the request through. Run your suite, or run the
app; then read the gaps back:

```bash
bin/rails current_scope:report
```

```
Would-be denials — grant these to stop them (most-denied first):

  Ada Lovelace — currently Member
      412x  reports#index
       38x  reports#export
  Grace Hopper
        7x  reports#approve

Total: 457 would-be denials across 2 subject(s).
```

That list is your migration plan, in the shape of the role grid you need to
build. Seed the roles it names, watch the list empty out, then set
`config.enforcement = :enforce`. Every step is one line back.

**Report mode is an adoption ramp, not a way to run in production.** It relaxes
exactly one thing — "nobody has granted this yet". It never lifts the
separation-of-duties veto, and it never opens the management console. Enabling it
in production logs a loud boot warning saying you are not enforcing
authorization; that warning is there because the failure mode is quiet, and a
temporary survey is exactly the kind of thing that quietly becomes permanent.

See the README's [Retrofitting an app that already has
users](../../README.md#retrofitting-an-app-that-already-has-users) for the short
version.

---

## Your authentication must run before the gate

**Symptom:** an anonymous visitor gets a blank `403` with
`X-Current-Scope-Reason: no_grant`, instead of being redirected to sign in.

**Cause:** the gate is a `before_action` registered when you `include
CurrentScope::Guard`. Callbacks run in the order they're declared. If the gate is
registered before your authentication callback, it runs first, sees a `nil`
subject, and — being fail-closed — denies. `nil` is not "anonymous, let the auth
layer handle it"; to a fail-closed gate, `nil` is "nobody granted this".

Two correct orderings. Either works; pick the one that matches your app.

```ruby
# 1. Declare authentication ABOVE the includes.
class ApplicationController < ActionController::Base
  before_action :authenticate_user!   # runs first

  include CurrentScope::Context
  include CurrentScope::Guard
end
```

```ruby
# 2. Or prepend it, if the include order is out of your hands
#    (a concern, an engine, a base class you don't own).
class ApplicationController < ActionController::Base
  include CurrentScope::Context
  include CurrentScope::Guard

  prepend_before_action :authenticate_user!   # jumps the queue
end
```

If you're unsure which is running first, the symptom tells you: a **blank 403**
means the gate won; a **redirect to sign-in** means auth won, which is what you
want.

---

## Devise (and any mounted engine)

Devise's controllers descend from your `ApplicationController`, so they inherit
the gate — and the gate denies them, because nobody can be granted
`devise/sessions#create` before they've signed in. You need **both** halves:

```ruby
# config/initializers/current_scope.rb
CurrentScope.configure do |config|
  config.excluded_controllers += [%r{\Adevise/}, %r{\Ausers/}]
end
```

```ruby
# and on the controllers themselves
class Users::SessionsController < Devise::SessionsController
  skip_before_action :current_scope_check!
end
```

**Why both**, since doing one and not the other is the usual mistake:

| You did | What happens |
|---|---|
| Excluded only | Guard **raises**. An excluded controller can't be granted, so gating it is a misconfiguration and the engine says so loudly rather than 403ing forever. |
| Skipped only | Works, but the controller stays in the catalog: dead rows in the permission grid that look grantable and mean nothing. |
| Both | Correct. Not gated, not offered. |

This generalises to any mounted engine whose controllers inherit from
`ApplicationController` — Sidekiq's web UI, ActiveAdmin, Blazer. If it renders
through your base controller, it inherits the gate.

---

## ⚠️ `skip_before_action` inherits, and it fails OPEN

**This is the one trap in this engine that fails open.** Everything else here
fails closed — unsure means refuse. This one is the opposite, and it's silent.

```ruby
class ApiController < ApplicationController
  skip_before_action :current_scope_check!   # for the health endpoint, you thought
end

class Api::OrdersController < ApiController
  # ...and every action here is now ungated. Nothing said so.
end
```

The skip is inherited by every subclass, forever. Worse: the permission grid
**still shows those actions as grantable**, so the UI actively tells you they're
protected. Someone ticking that box is ticking nothing.

### Safe patterns

**Prefer skipping on leaf controllers** — the ones nothing inherits from:

```ruby
class SessionsController < ApplicationController   # nothing subclasses this
  skip_before_action :current_scope_check!
end
```

**Or re-assert the gate in the subclass**, if you must skip on a base:

```ruby
class Api::OrdersController < ApiController
  before_action :current_scope_check!   # take it back
end
```

### How to detect it

Include `GatingTripwire` on the base you want verified, and **run your suite**:

```ruby
class ApplicationController < ActionController::Base
  include CurrentScope::Context
  include CurrentScope::Guard
  include CurrentScope::GatingTripwire   # dev/test aid
end
```

It's a separate `after_action`, so `skip_before_action :current_scope_check!`
doesn't skip it — it fires on the inherited-skip action, finds the gate never
ran, and raises. That's the concrete detection step, and it's why running the
suite with the tripwire on is worth doing once per rollout.

Mark genuinely-public actions so it doesn't cry wolf:

```ruby
class ApiController < ActionController::Base
  include CurrentScope::GatingTripwire
  current_scope_skip_tripwire! only: :health
end
```

### The residual, stated honestly

The tripwire is **a dev/test aid, not a production net**, and being an
`after_action` it can't see an action that renders from a halted `before_action`.
So a controller that skips the gate and stays in the catalog is: ungated in
production, undetectable at runtime, and rendered as grantable in the UI.

That gap is real and currently open — tracked in
[#62](https://github.com/davidteren/current_scope/issues/62). Until it closes,
the mitigations above are mitigations, not a fix. Prefer leaf skips.

---

## Two inventories, two different questions

These get confused, so: they are complementary, not alternatives.

| | Answers | Where |
|---|---|---|
| **`GatingTripwire`** | "Which actions run **ungated**?" — no gate at all | dev/test, raises |
| **`config.enforcement = :report`** | "Which actions are gated but **ungranted**?" — the gate ran and would have refused | anywhere, logs |

Report mode is silent about an ungated controller, because the gate never runs to
report anything. The tripwire is silent about a missing grant, because the gate
ran fine. A retrofit wants both: the tripwire to find what you forgot to gate,
report mode to find what you forgot to grant.

---

## Coexisting with Pundit, CanCanCan, or Action Policy

You do not have to rip out your existing authorization to start. They occupy
different seams and can run side by side:

- **CurrentScope gates at the controller boundary** — may this subject run this
  action at all?
- **Your existing policies stay for record-level rules** — the per-record
  predicates, the scopes — until you port them.

A workable order:

1. Turn on `Context` + `Guard` in **report mode**. Nothing changes for users.
2. Seed roles from `current_scope:report` until the list is empty.
3. Flip to `:enforce`. Both systems now run; the gate admits, your policies still
   decide records.
4. Port record rules incrementally: `authorize` / `policy_scope` become
   `allowed_to?` / `scope_for`. A scoped role ("Editor of Project #7") is usually
   what an ownership predicate was approximating.
5. Delete the old policy once nothing calls it.

Nothing about steps 1–3 requires touching a single policy. That's deliberate —
the risky part of a migration isn't the typing, it's the window where you can't
tell whether you changed who can do what.

Tooling to do the mapping and prove equivalence before you cut over is tracked in
[#45](https://github.com/davidteren/current_scope/issues/45).

---

## Namespaced and hybrid apps: grants come in pairs

`items#index` and `api/v1/items#index` are **independent permission keys**. The
catalog derives from routes, so the same resource reached through two controllers
is two rows in the grid, and granting one grants nothing about the other.

If your app serves both HTML and an API over the same records, every role needs
both ticked — or your API 403s for people who can use the web UI fine. This bites
during a rollout because the HTML side is usually what gets tested first.

The same split affects short-form checks. `allowed_to?(:show, item)` derives
`items#show` from the record's route key, which is *not* what
`Api::V1::ItemsController`'s gate enforces. See the README's [namespaced /
custom-named controllers foot-gun](../../README.md#checking-permissions--anywhere)
— pass the explicit key when the two diverge:

```ruby
allowed_to?("api/v1/items#show")
```

In development and test, `config.warn_on_cross_controller_derivation` logs a
nudge when a derived key diverges from the gate on the current controller. It
warns once per site, and it names both readings — asking about a different
resource than the controller handles derives a different key too, and that's
correct. See [Dev diagnostics](../../README.md#dev-diagnostics).

---

## A rollout ladder

Roughly in order. Steps 1–3 change nothing for users.

1. **Install, mount, and set `config.enforcement = :report`.** Fix the callback
   ordering above; add your Devise/engine skips + exclusions.
2. **Inventory the ungated surface.** Add `GatingTripwire` to your base in
   dev/test and run the suite. Fix what it finds — inherited skips first.
3. **Inventory the ungranted surface.** Exercise the app, then
   `bin/rails current_scope:report`. Seed the roles it names.
4. **Flip one namespace to `:enforce`?** You can't — enforcement is global. What
   you *can* do is watch `current_scope:report` empty out and flip once. If you
   want a narrower blast radius, roll out `Guard` itself one base controller at a
   time (include it on `Admin::BaseController` before `ApplicationController`).
5. **Flip to `:enforce`.** Keep the diagnostics on in dev/test — they're on by
   default and they're how the next mistake tells on itself.
6. **Broaden `excluded_controllers` only deliberately.** Every entry is a
   controller that can never be granted; that's a decision, not a cleanup.

---

## See also

- [README — Retrofitting an app that already has users](../../README.md#retrofitting-an-app-that-already-has-users)
- [README — Dev diagnostics](../../README.md#dev-diagnostics)
- [#62](https://github.com/davidteren/current_scope/issues/62) — the skip-inheritance fail-open gap
- [#45](https://github.com/davidteren/current_scope/issues/45) — assisted migration from Pundit / CanCanCan / Action Policy
