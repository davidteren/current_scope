# Impersonation (act-as)

> See also: [Concepts & glossary](concepts-and-glossary.md).

## Impersonation (act-as)

`Current` distinguishes the **effective subject** (`current_scope_user` — who
the request acts as) from the **real actor** (`current_scope_actor` — who is
actually behind it). They're the same person until an admin impersonates
someone; then permission checks read the subject while attribution reads the
actor. `current_scope_actor` falls back to the subject, so it's never nil and
you never write a nil branch. `impersonating?` is the read-only-state signal
for views (show a banner, disable destructive controls).

Point `actor_method` at the host method that returns the real actor:

```ruby
# config/initializers/current_scope.rb
config.actor_method = :true_user
```

> **`actor_method` is security-critical, not an optional extra.** The entire
> act-as security model keys off `actor != user`. If you impersonate but leave
> `actor_method` unset, `actor` falls back to `user`, so it all *looks* fine in
> manual testing while being silently inert: the read-only-while-impersonating
> `MutationGuard` never engages, the SoD `:either` veto can't fire, and every
> audit row is attributed to the impersonated subject instead of the real
> admin. The permission path can't detect this, but the boundary API can:
> calling `CurrentScope.record_impersonation_started!` with `actor_method` unset
> **raises** — that call is your declaration that impersonation is live, so a
> missing `actor_method` there is unambiguously a misconfiguration. (A host that
> impersonates without ever calling the boundary API gets no runtime signal —
> so set `actor_method` whenever you set up act-as.)

The host owns the act-as switch — CurrentScope only reads it. The recipe:

```ruby
class ApplicationController < ActionController::Base
  include CurrentScope::Context
  include CurrentScope::Guard

  private

  # The real actor: always the signed-in account, never the impersonated one.
  def true_user = current_user

  # The effective subject: re-resolved from the session EVERY request, never
  # cached in Current (which is per-request and must not be trusted across
  # requests). Falls back to the real actor when not impersonating.
  def current_scope_user
    return true_user unless session[:impersonated_subject_id]

    User.find_by(id: session[:impersonated_subject_id]) || true_user
  end
end
```

Wire `current_scope_user` in as your `user_method`, or override the reader as
above. Start and stop act-as through state-changing verbs (CSRF-protected),
and authorize **who** may impersonate — this is a privilege escalation surface:

```ruby
class ImpersonationsController < ApplicationController
  def create   # POST /impersonation
    head :forbidden and return unless allowed_to?(:create, controller: "impersonations")
    session[:impersonated_subject_id] = params.expect(:subject_id)
    redirect_to root_path
  end

  def destroy  # DELETE /impersonation
    session.delete(:impersonated_subject_id)
    redirect_to root_path
  end
end
```

Clear the impersonation on **both** sign-in and sign-out
(`session.delete(:impersonated_subject_id)`) so an act-as session can never
outlive the login that started it or bleed into the next one.

### Impersonated sessions are read-only by default

An impersonated session can look, but not touch: with `actor_method` set,
every non-`GET`/`HEAD` request is denied while a real actor stands behind a
different subject — **including the engine's own management UI** (editing roles
and grants is the highest-value surface to keep read-only). This gate is a
*separate* `before_action` from the permission check, so it survives
`skip_before_action :current_scope_check!` and runs *first*. Flip
`config.allow_mutations_while_impersonating = true` to allow writes (at which
point the SoD `:either` veto above becomes the observable line of defense).

**Production refuses this flag by default.** Letting a real actor write as the
subject they impersonate is a privilege-escalation and audit-integrity risk, so
`config.allow_mutations_while_impersonating = true` **raises at boot in
production** unless you set `CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS` in
the environment. An unsafe deploy fails loudly instead of running silently
insecure. `development`, `test`, and `staging` are unaffected — the flag works
there with no env var. Assigning `false` (the default) never raises anywhere.
The escape hatch exists for cases like a live public showcase whose whole point
is demonstrating impersonated actions; a real production app should almost
always leave impersonated sessions read-only.

Because it runs first, the endpoints that **end** an impersonation must opt
out — your stop-impersonation, sign-out, **and** sign-in actions — or you could
never turn act-as off (and sign-in could never clear it):

Clearing the mutation guard alone is **not** enough. The two gates are separate
`before_action`s, so skipping one leaves the other running: the impersonated
subject usually holds no grant for `sessions#destroy` or `impersonations#destroy`,
and the permission gate then 403s the very request that would end act-as. Skip
**both** on these endpoints:

```ruby
class SessionsController < ApplicationController
  current_scope_skip_gate!(reason: "sign-in must run without a grant")
  skip_before_action :current_scope_mutation_guard!   # sign-in/out ends act-as
end

class ImpersonationsController < ApplicationController
  # Scoped to :destroy on purpose — STARTING an impersonation stays gated.
  # With only:/except: the grid still marks the row (the reason is a
  # whole-controller annotation), but the skip runs.
  current_scope_skip_gate!(reason: "stop act-as must not need the impersonated subject's grant",
                           only: :destroy)
  skip_before_action :current_scope_mutation_guard!, only: :destroy   # stop act-as
end
```

Denials raise `CurrentScope::AccessDenied` with stable accessors for branded
403 pages and error trackers (prefer `#permission` over parsing `#message`):

| Accessor | Meaning |
|---|---|
| `#permission` | denied `controller#action` key — the stable API. Defaults to the positional message when `permission:` is omitted |
| `#message` | `StandardError` message. Gem raise sites pass the key as both message and permission; they can diverge if a caller passes an explicit `permission:` keyword |
| `#reason` | machine-readable cause (also on `X-Current-Scope-Reason`) |
| `#record` | the record under decision when the gate had one; **nil** on collection / impersonation-gate denials |
| `#subject` | effective subject when known |

| Reason | Means |
|---|---|
| `sod_veto` | the record's initiator can't perform a separation-of-duties action on it |
| `no_grant` | nothing granted the permission — the default deny |
| `model_undeclared` | a record-less deny that a scoped grant would have opened, had the controller declared `current_scope_model` |
| `model_invalid` | `current_scope_model` was declared but returned something other than a concrete ActiveRecord class |
| `impersonation_gate` | a mutation while impersonating, which is read-only |
| `not_full_access` | the management UI, which only full-access subjects enter |

Guard and MutationGuard denials route through one method
(`current_scope_denied`), so by default a refusal on a Guard-wrapped controller
gets its reason header (and the denial log line below). "By default" matters: a
host `rescue_from CurrentScope::AccessDenied` registered after the include
**replaces** that method, and with it the header and the log line (see the last
example in this section). A **host** denial is a
bodyless `403` by default — the reason header is the signal, and the gem won't
render into your app's response contract. The engine's own management UI is the
exception: it overrides the body seam to render a short page saying a full-access
role is required, because the person reading that one is an admin looking at a
browser.

The engine also registers `CurrentScope::AccessDenied → :forbidden` in
`ActionDispatch` rescue responses (only if the host has not already mapped that
class), so a denial that **escapes** Guard (PORO re-raise, Context-only
controller) is still HTTP **403**, not 500. That path is status-only — no
`X-Current-Scope-Reason` header and no denial log line unless something in your
stack writes them. On the Guard path, rescued denials log one INFO line
mirroring the header:

```
[CurrentScope] denied reports#approve (no_grant) → 403
```

INFO is intentional so production captures denials without raising the log
level; high-volume anonymous probes will grow the log — filter
`[CurrentScope] denied` if that is noise for your operators.

**Branded host 403 — prefer the body seam** so the header and log stay intact:

```ruby
# Keeps X-Current-Scope-Reason + the denial log; only the body changes.
def current_scope_render_denied(reason)
  render "errors/forbidden", status: :forbidden, locals: { reason: reason }
end
```

Need `#permission` / `#record` / `#subject` on the page? A host `rescue_from`
registered **after** `include CurrentScope::Guard` wins and **replaces**
`current_scope_denied` — set the header yourself (or you lose it), and note
this example restores only the header; write your own log line if you need
the denial telemetry:

```ruby
rescue_from CurrentScope::AccessDenied do |e|
  response.headers["X-Current-Scope-Reason"] = e.reason.to_s if e.reason
  render "errors/forbidden",
         status: :forbidden,
         locals: { permission: e.permission, reason: e.reason, record: e.record }
end
```

**View/gate disagreement is by design.** `allowed_to?` is HTTP-ignorant: it
still returns `true` for a permission the subject genuinely holds, even though
the mutation gate will `403` the resulting non-GET click while impersonating.
Drive read-only affordances off `impersonating?` — render a banner, disable or
hide destructive controls — rather than expecting `allowed_to?` to hide them.

> The audit boundary events for act-as (recording who impersonated whom, and
> when it stopped) land in a later unit — this section is the resolution
> plumbing only.

`Current` is request-scoped and does **not** flow into Active Job. When a job
needs the subject or actor, pass GlobalIDs (or ids) as arguments and re-resolve
inside `perform` — never read `CurrentScope::Current` from a job.
