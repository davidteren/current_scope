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

### Configuration

Everything lives in `config/initializers/current_scope.rb` (created by the
install generator): the `user_method`, the `subject_class`, `sod_actions`,
`excluded_controllers` (keep infrastructure out of the grid), and
`parent_controller` (what the management UI inherits from).

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

[`showcase/`](showcase/) is a standalone, deployable Rails 8.1 host app
(Hotwire, ViewComponent, the built-in authentication generator) validating
every mechanism end to end — RBAC matrix, SoD veto at the gate and in the view,
scoped roles opening exactly one record, and the management UI. It depends on
the engine via a local path gem and runs on its own: `cd showcase && bin/rails
db:setup && bin/rails server`. `db:setup` seeds four users (`owner@` /
`reviewer@` / `member@` / `scoped@example.com`, password `password`) exercising
each path.

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
