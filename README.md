# CurrentScope

**Authorization as data you edit in a UI, not rules you hardcode and redeploy —
with one ambient context that makes `allowed_to?` work identically in
controllers, views, and components.**

CurrentScope is a mountable Rails engine. You add the gem, run the install
generator, and get:

- **Permissions auto-derived from your routes.** Every `controller#action`
  pair *is* a permission. Add an `OrdersController` and its actions appear in
  the permission grid with zero wiring.
- **Roles as rows, not classes.** A role is a named, editable bundle of
  permissions — ticked cells on a controller × action grid. Change what
  "Reviewer" means without a deploy.
- **Scoped roles.** The same role, attached to one specific record: "Editor of
  Project #7" grants nothing on Project #8.
- **A separation-of-duties veto.** Whoever initiated a record can never
  approve it — not grantable, not configurable in the UI, overrides even full
  access. A structural guarantee, not a preference.
- **Fail-closed resolution.** No grant means denied. Everything is a
  permission, even the baseline things every signed-in user can do.
- **An ambient authorization context.** The current subject flows through
  `ActiveSupport::CurrentAttributes` from the controller gate down to the
  smallest ViewComponent. The view can never disagree with the gate — they ask
  the same resolver.

The decision order, fixed:

```
1. SoD veto        → initiator of the record?            DENY (overrides all)
2. full_access     → role grants everything, forever     ALLOW
3. org-wide role   → role's permission set includes it   ALLOW
4. scoped role     → a role held on THIS record          ALLOW
5. otherwise       → default deny
```

## Installation

```ruby
# Gemfile
gem "current_scope"
```

```bash
bin/rails generate current_scope:install
bin/rails current_scope:install:migrations && bin/rails db:migrate
```

Include the concerns in `ApplicationController` — `Context` populates the
ambient subject from your authentication, `Guard` gates every action behind
its own `controller#action` permission:

```ruby
class ApplicationController < ActionController::Base
  include CurrentScope::Context   # sets CurrentScope::Current.user from current_user
  include CurrentScope::Guard     # fail-closed gate on every action
end
```

Skip the gate where authorization doesn't apply (sign-in, webhooks):

```ruby
class SessionsController < ApplicationController
  skip_before_action :current_scope_check!
end
```

Seed the baseline roles and give yourself the keys:

```ruby
# db/seeds.rb
CurrentScope.seed_defaults!   # Owner (full_access) + Member
CurrentScope::RoleAssignment.create!(
  subject: User.first, role: CurrentScope::Role.find_by!(name: "Owner"))
```

Then manage everything at `/current_scope` (full-access subjects only): the
role grid, org-wide assignments, scoped grants.

## Usage

### Checking permissions — anywhere

`allowed_to?` is available in controllers and views via `Context`, and in any
PORO or ViewComponent by mixing in `CurrentScope::Permissions`. No
`current_user` threading, ever:

```ruby
allowed_to?(:approve, report)         # key derived from the record → reports#approve
allowed_to?(:create, Report)          # class form for collection actions
allowed_to?("admin/reports#approve")  # explicit key when you need it
```

Key derivation always agrees with the gate: when the *current* controller
handles the record's type (including under a namespace — `admin/reports` for
a `Report`), its controller path wins; otherwise the record's route key is
used. Cross-resource checks (`allowed_to?(:approve, report)` from a projects
view) therefore resolve to `reports#approve`, while the same call inside
`Admin::ReportsController` resolves to `admin/reports#approve` — exactly what
the Guard enforces there.

```ruby
class ApproveButtonComponent < ViewComponent::Base
  include CurrentScope::Permissions

  def render? = !report.approved? && allowed_to?(:approve, report)
end
```

### Scoping a list (`scope_for`)

`allowed_to?` answers "may I act on **this** record?". `scope_for` answers the
list-side question — "**which** records may I act on?" — from the *same* roles,
permissions, and scoped grants the gate reads. Use it for index pages so the
list and the per-record gate stay one source of truth, never a hand-written
query that drifts:

```ruby
# app/controllers/projects_controller.rb
def index
  @projects = scope_for(Project).order(created_at: :desc).page(params[:page])
end
```

- **full-access or an org-wide grant** of the key → every record (`Project.all`).
- **scoped grants** → only the specific records that role was granted on.
- **no grant** (or no subject) → empty, fail-closed like the gate.

It returns a chainable `ActiveRecord::Relation`, so `.where`/`.order`/`.page`
compose normally. `permission:` defaults to the model's `index` key and accepts
a bare action or a full key (`scope_for(Report, permission: :approve)`).

Every record `scope_for(Project)` returns passes `allowed_to?(:index, project)`,
and every record it omits fails it — by construction, not by convention. It
resolves against the **effective** subject, so acting-as changes what lists
show, and it is **flat**: a scoped grant lists that record only (parent/child
cascade is deferred). SoD does not apply — it vetoes record-targeted *actions*,
not list membership.

### Record-level decisions

Member actions that need scoped roles or the SoD veto declare a hook. It runs
*before* your own `before_action`s (the gate comes first), so it loads the
record itself; memoize so your `set_*` callback reuses it. Key off
`request.path_parameters`, never `params` — a `?id=` query string must not
smuggle a record into collection actions:

```ruby
class ReportsController < ApplicationController
  private

  def set_report = @report ||= Report.find(params.expect(:id))

  def current_scope_record
    set_report if request.path_parameters[:id]
  end
end
```

### Scopeable models

`include CurrentScope::Scopeable` in a host model to list it in the scoped-role
picker's type dropdown, and give records a nice label with `current_scope_label`:

```ruby
class Project < ApplicationRecord
  include CurrentScope::Scopeable

  def current_scope_label = "#{name} (##{id})"   # optional; defaults to "Project ##{id}"
end
```

This is **browse-only sugar** — it does *not* gate anything. The raw-GlobalID
path still accepts **any** model as a scoped-role target whether or not it opts
in; the mixin only decides what shows up in the dropdown. `current_scope_label`
is a plain instance method, so your own definition always wins over the default.

### Separation of duties

Declare who initiated a record; the resolver does the rest for the configured
actions (default: `approve`):

```ruby
class Report < ApplicationRecord
  def current_scope_initiator = requested_by
end
```

The veto fails **loud, not open**: if an SoD action reaches a record whose
class doesn't define the hook, the resolver raises a `ConfigurationError`
instead of silently permitting. Return `nil` from the hook to exempt a record
type, or trim `config.sod_actions`.

**Don't need separation of duties?** Empty the list:

```ruby
# config/initializers/current_scope.rb
config.sod_actions = []   # disable the SoD veto entirely
```

With no configured actions the veto step is a no-op, and the resolver collapses
to `full_access → org-wide role → scoped role → deny`. No model needs
`current_scope_initiator` — the `ConfigurationError` above only fires for
actions that are *in* `sod_actions`, so an empty list never raises. `sod_identity`
becomes moot; roles, scoped roles, `scope_for`, audit, and impersonation are
unaffected. This is opt-out by configuration, not a fork of the resolver.

By default (`config.sod_identity = :either`) the veto weighs **two**
identities: the effective subject *and* the real actor behind an impersonated
session. So an admin who initiated a report can't slip past the veto by
approving it while impersonating someone else — impersonation can never approve
your own record. Set `:subject` to weigh only the effective subject. The two
are identical when nobody is impersonating (`actor == subject`), so v0.1 hosts
see no change.

### Configuration

Everything lives in `config/initializers/current_scope.rb` (created by the
install generator): the `user_method`, the `subject_class`, `sod_actions`,
`excluded_controllers` (keep infrastructure out of the grid), and
`parent_controller` (what the management UI inherits from). The three
impersonation knobs — `actor_method`, `allow_mutations_while_impersonating`,
and `sod_identity` — are grouped in their own block and covered under
[Impersonation](#impersonation-act-as); they layer in that order, so
`sod_identity` is only observable once a mutation is allowed past the read-only
gate.

Two loud-by-design behaviors: a controller excluded from the catalog can't be
granted, so gating it is a misconfiguration — Guard raises and tells you to
either stop excluding it or `skip_before_action :current_scope_check!`. And a
`user_method` that the controller doesn't respond to raises instead of
silently turning every request into a 403.

### Impersonation (act-as)

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

#### Impersonated sessions are read-only by default

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

```ruby
class SessionsController < ApplicationController
  skip_before_action :current_scope_mutation_guard!   # sign-in/out ends act-as
end

class ImpersonationsController < ApplicationController
  skip_before_action :current_scope_mutation_guard!, only: :destroy   # stop act-as
end
```

Denials carry a machine-readable reason (`:sod_veto`, `:no_grant`,
`:impersonation_gate`) on `AccessDenied#reason`, surfaced on the response as the
`X-Current-Scope-Reason` header.

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

### Testing your app

```ruby
require "current_scope/test_helpers"

class ApproveButtonComponentTest < ViewComponent::TestCase
  include CurrentScope::TestHelpers

  test "renders for a reviewer" do
    with_current_user(users(:reviewer)) do
      render_inline ApproveButtonComponent.new(report: reports(:pending))
      assert_selector "button", text: "Approve"
    end
  end
end
```

`CurrentAttributes` resets around every request, job, and test — the ambient
subject cannot leak between executions.

## The showcase app

The engine has a full companion **showcase** — a standalone, deployable Rails
8.1 host app (Hotwire, ViewComponent, built-in auth) that dramatizes every
mechanism end to end: a multi-domain anti-fraud gallery (payroll / contracts /
expenses), one-click "act as", a guided "try to commit fraud → refused"
walkthrough, the auto-derived permission grid, and the management UI. It lives
in its own repository:

**→ [davidteren/current_scope_showcase](https://github.com/davidteren/current_scope_showcase)**

Run it locally alongside this engine (checked out as a sibling directory):

```bash
git clone https://github.com/davidteren/current_scope
git clone https://github.com/davidteren/current_scope_showcase
cd current_scope_showcase
bin/setup          # bundle (resolves the engine at ../current_scope), seed the DB
bin/rails server   # http://localhost:3000
```

## Design notes

- [`resources/DESIGN.md`](resources/DESIGN.md) — the original design-concept
  capture (under the placeholder name "Grantwork").
- [`docs/RESEARCH.md`](docs/RESEARCH.md) — the research behind the ambient
  context: Evil Martians / Vladimir Dementyev (palkan) on CurrentAttributes
  vs dry-effects vs explicit passing, and what this gem borrows from Action
  Policy.

## License

The gem is available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
