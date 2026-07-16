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
| Skipped only | Works, but the controller stays in the catalog: dead rows in the permission grid whose routed-action ticks mean nothing — the grid badges them "gate not run" (an unconditional skip is provable), but they're still clutter that excluding removes. (One exception: with break-glass on, an injected `bypass_sod` cell on such a row is **live** — the grid marks it exempt.) |
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

The skip is inherited by every subclass, forever. The permission grid used to
**show those actions as grantable with nothing saying otherwise** — the UI
actively told you they were protected while ticking that box ticked nothing.
The grid now badges a row **"gate not run"** when the callback chain *proves*
the gate never runs there (a bare or inherited skip, or a controller that never
included `Guard`). The badge is proof-only: a *conditional* skip
(`only:`/`except:`) is unprovable statically and renders unmarked — the grid's
own hint says an unmarked row is not proof, and `config.gating_tripwire = :warn`
catches that shape at runtime (below).

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

Three tools, from cheapest to deepest:

**1. The grid badge — automatic.** Open the role editor: any controller
provably ungated is marked "gate not run". No setup. It only marks what the
callback chain proves — conditional skips render unmarked.

**2. `bin/rails current_scope:ungated` — the same inventory as a command.**
No mixin, no deploy, no traffic; run it against your real app and read the
list. Its output states its own limit and routes conditional skips to the
tripwire.

**3. `GatingTripwire` — the runtime net.** Include it on the base you want
verified, and **run your suite**:

```ruby
class ApplicationController < ActionController::Base
  include CurrentScope::Context
  include CurrentScope::Guard
  include CurrentScope::GatingTripwire   # raises in dev/test; :warn elsewhere
end
```

It's a separate `after_action`, so `skip_before_action :current_scope_check!`
doesn't skip it — it fires on the inherited-skip action, finds the gate never
ran, and **raises (the dev/test default) or logs once per `controller#action`
(`config.gating_tripwire = :warn`, the default outside dev/test)**. Because it
keys on whether the gate actually ran, it catches the shapes the static tools
can't prove — a conditional skip's skipped action warns; its gated actions stay
silent. That's the concrete detection step, and it's why running the suite with
the tripwire on is worth doing once per rollout — and why `:warn` in production
turns it into an inventory instead of a 500.

Mark genuinely-public actions so it doesn't cry wolf:

```ruby
class ApiController < ActionController::Base
  include CurrentScope::GatingTripwire
  current_scope_skip_tripwire! only: :health
end
```

### The residual, stated honestly

#62 named three symptoms with one cause. Two are closed; one is open on
purpose:

- **"Rendered as grantable in the UI" — closed for everything provable.** The
  grid badges bare skips, inherited skips, and never-included-`Guard`
  controllers. The one grid residual: a *conditional* skip renders unmarked,
  because its answer is unprovable statically — that shape is caught at runtime
  by `:warn` (this PR) and gets a static third state in
  [#75](https://github.com/davidteren/current_scope/issues/75).
- **"Undetectable at runtime" — closed for any action that completes.**
  `config.gating_tripwire = :warn` makes the tripwire a production inventory
  instead of a 500, and `bin/rails current_scope:ungated` answers statically
  with no deploy at all. The tripwire's `after_action` blind spot (below)
  still applies: a request halted by an earlier `before_action` never reaches
  it, so that shape stays a named residual, not a closed one.
- **"Ungated in production" — still true, deliberately.** This is detection,
  not prevention: the skip still inherits and still fails open. What changed
  is that it can no longer be invisible. The declared-skip macro that would
  make intent explicit is
  [#76](https://github.com/davidteren/current_scope/issues/76).

Two honest limits survive: the tripwire is an `after_action`, so it can't see
an action that renders from a halted `before_action` (unchanged); and every
static tool here marks only what it can prove. The mitigations above — leaf
skips, re-asserting the gate — are still the right habits.

---

## Two inventories, two different questions

These get confused, so: they are complementary, not alternatives.

| | Answers | Where |
|---|---|---|
| **`bin/rails current_scope:ungated`** | "Which controllers **provably never run the gate**?" — static, from the callback chain | anywhere, no traffic, no mixin |
| **`GatingTripwire`** | "Which actions run **ungated**?" — no gate at all, including shapes the static tools can't prove | raises in dev/test; `config.gating_tripwire = :warn` logs once per action elsewhere |
| **`config.enforcement = :report`** | "Which actions are gated but **ungranted**?" — the gate ran and would have refused | anywhere, logs |

Report mode is silent about an ungated controller, because the gate never runs to
report anything. The tripwire is silent about a missing grant, because the gate
ran fine. A retrofit wants both: the tripwire (or the `ungated` task) to find
what you forgot to gate, report mode to find what you forgot to grant.

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
   `bin/rails current_scope:report`. Seed the roles it names. If any of your
   controllers use **scoped grants** for their list pages, declare
   `def current_scope_model = TheType` on each — a scoped grant opens a
   collection gate only for the type the controller names, and report mode's
   `model_undeclared` rows (with the dev nudge) point you at the ones that
   need it.
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
- [#62](https://github.com/davidteren/current_scope/issues/62) — the skip-inheritance fail-open; its detection half shipped (grid badge, `current_scope:ungated`, `:warn` posture), the fail-open itself remains by design ([#76](https://github.com/davidteren/current_scope/issues/76) is the declared-skip macro)
- [#45](https://github.com/davidteren/current_scope/issues/45) — assisted migration from Pundit / CanCanCan / Action Policy
