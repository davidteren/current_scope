# CurrentScope

[![Gem Version](https://img.shields.io/gem/v/current_scope)](https://rubygems.org/gems/current_scope)
[![CI](https://github.com/davidteren/current_scope/actions/workflows/ci.yml/badge.svg)](https://github.com/davidteren/current_scope/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](MIT-LICENSE)
[![Website](https://img.shields.io/badge/website-davidteren.github.io%2Fcurrent__scope-4d7cfe)](https://davidteren.github.io/current_scope/)
[![Status: beta](https://img.shields.io/badge/status-beta-4d7cfe)](https://github.com/davidteren/current_scope/issues/116)

> ## 🧪 Beta — usable, and we want your feedback
>
> The core is built and security-hardened: permissions derived from your routes,
> roles as editable data, per-record scoped grants, a separation-of-duties veto,
> impersonation, an append-only audit ledger, and a report-only rollout mode. The
> one published security defect in grant-id storage
> ([#151](https://github.com/davidteren/current_scope/issues/151)) is fixed and
> released in 0.5.0; the affected older versions are yanked.
>
> It is **not yet certified for production**, for one honest reason: the last gate
> to general availability is a real-world bake — one real app running
> `config.enforcement = :report`, reading `bin/rails current_scope:report`, then
> flipping to `:enforce`. Until a real host has run it enforced, "production-ready"
> is a claim with nothing behind it. That gate is tracked in
> [#116](https://github.com/davidteren/current_scope/issues/116); **1.0 is when it
> closes.**
>
> So please adopt it, run it in `:report` mode, and tell us what breaks — that
> feedback is exactly what gets it to 1.0. It is an **authorization** library, so
> mind the bar: a bug here is a user seeing or doing something they shouldn't.
> Anything you find goes on the
> [issue tracker](https://github.com/davidteren/current_scope/issues).

**Website:** [davidteren.github.io/current_scope](https://davidteren.github.io/current_scope/) —
overview, quickstart, the
[separation-of-duties guide](https://davidteren.github.io/current_scope/separation-of-duties.html),
the security checklist, and
[copy-paste prompts for AI agents](https://davidteren.github.io/current_scope/ai-agents.html).
Source lives in [`docs/site/`](docs/site/).

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
  Project #7" grants nothing on Project #8. A model can opt in to reaching down a
  declared chain with `current_scope_parent :project`, so a role held on a
  project covers that project's reports — including reports created after the
  grant, and up to five hops of nesting.
  Flat is still the default, a scoped `full_access` grant deliberately does not
  cascade, and the four-eyes veto keeps reading the record you handed it. See
  [Checking permissions](docs/guides/checking-permissions.md#a-grant-on-a-parent-record-108).
- **An optional separation-of-duties veto.** Off by default; opt in by listing
  actions. Once on, whoever initiated a record can never approve it — not
  grantable, not configurable in the UI, overrides even full access. A
  structural guarantee, not a preference.
- **Fail-closed resolution.** No grant means denied. Everything is a
  permission, even the baseline things every signed-in user can do.
- **An ambient authorization context.** The current subject flows through
  `ActiveSupport::CurrentAttributes` from the controller gate down to the
  smallest ViewComponent. The view can never disagree with the gate — they ask
  the same resolver.

The decision order, fixed:

```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever     ALLOW
3. org-wide role   → role's permission set includes it   ALLOW
4. scoped role     → a role held on THIS record, or an   ALLOW
                     ancestor role that ticks the key
                     (opt-in; not scoped full_access)
5. record-less     → no record: a scoped grant of the     ALLOW
                     named type opens a listed
                     collection read (index by default)
6. otherwise       → default deny
```

Step 4 also matches a grant on a declared parent when the child opted in
with `current_scope_parent`. Step 5 is why a scoped-only subject can reach
an index. A collection action names the type with `current_scope_model`.
The class form `allowed_to?(:index, Report)` names the type itself.
Without a type the gate stays closed. The listed read still opens only
when the subject's scoped list is not empty, including rows reached
through a declared parent. Other record-less keys (for example `create`)
need an explicit tick on the named type; a scoped `full_access` grant
does not open those. An action in `config.sod_actions` never opens on
this arm: the veto needs a record. See
[Checking permissions](docs/guides/checking-permissions.md#scoping-a-list-scope_for).

## Screenshots

The mounted management UI at `/current_scope` — self-contained (no web fonts, no
build step, CSP-safe), first-class light **and** dark themes.

**Permission grid** — one row per controller, CRUD action groups derived from
your routes; ticked cells glow, a partial group reads as indeterminate. A route
whose controller class is missing (stale or typo) still appears — the catalog
mirrors routes — but the row is badged **no controller** so you do not grant a
key that only 500s. Remove the route or add the class;
`excluded_controllers` can hide the row if you want it out of the grid.

![Permission grid](docs/screenshots/permission-grid.png)

**Subjects** — everyone who can hold a role, their one org-wide role, and any
per-record scoped roles; server-side search across all subjects.

![Subjects](docs/screenshots/subjects.png)

| Roles | Members | Events |
|---|---|---|
| ![Roles](docs/screenshots/roles.png) | ![Members](docs/screenshots/members.png) | ![Events](docs/screenshots/events.png) |

Screenshot regenerate command: [CONTRIBUTING.md](CONTRIBUTING.md).

## Is it the right fit?

Authorization is a decision you live with for years, so the docs site carries a
comparison written to help you say **no** as easily as yes:
**[Is it the right fit?](https://davidteren.github.io/current_scope/comparison.html)**
— CurrentScope beside Pundit, Action Policy, CanCanCan, Banken and Oso, six
questions that narrow it down for you, and what adopting it actually costs
(source: [docs/site/comparison.md](docs/site/comparison.md)). The six questions
never answer "Banken": it has had no release since 2019, so it is covered in the
side-by-side table on that page, where you can weigh that for yourself, rather
than handed to you as a recommendation.

The trade in one line: **the others put your rules in code you deploy, Oso puts
them in a policy language, CurrentScope puts them in rows an administrator
edits.** So:

<!-- Mirrors docs/site/comparison.md, the source of truth for this list. -->

| Reach for something else when | Because |
|---|---|
| Rules depend on the record's data or the time ("only under 10,000") | CurrentScope has no vocabulary for attribute rules. Pundit, Action Policy, CanCanCan and Oso do. |
| Something outside Rails needs the same answer | It is a Rails engine. Oso is built for one policy across services. |
| Every permission change should be a code review | That is a legitimate policy, and an argument for Pundit or Action Policy. |
| You want the smallest possible dependency | Pundit is a convention and a few hundred lines; this brings tables, a UI and a ledger. |
| You cannot ship beta | The last gate before 1.0 is a real-host bake ([#116](https://github.com/davidteren/current_scope/issues/116)). |

Reach for CurrentScope when roles change often and not by developers, access is
per record rather than per class, somebody has to answer "who could approve this,
and when did that change?", or you are retrofitting a live app and need report
mode to tell you what would break.

## Installation

> **Upgrading from 0.4 or earlier? Run the migrations.** 0.5 widens the columns
> that store a grant's subject and resource id, so UUID and other string primary
> keys are stored whole instead of being truncated to an integer
> ([#151](https://github.com/davidteren/current_scope/issues/151) — two subjects
> could collapse into one identity, and one inherit the other's roles). Run
> `bin/rails current_scope:install:migrations && bin/rails db:migrate && bin/rails db:test:prepare`; the engine
> refuses to boot until you do. If MySQL was loaded from `schema.rb`, also run
> `bin/rails current_scope:repair_schema`, then the same task under
> `RAILS_ENV=test`, because `db:test:prepare` loads that same `schema.rb`. It
> applies the binary collation and changes nothing when the columns are already
> right. Integer, UUID and ULID keys all work, up to 64 characters. See
> [UPGRADING.md](UPGRADING.md).

This is the **canonical greenfield quickstart** (new app, or install before
users hit gated controllers). The same numbered path lives on the
[docs site](https://davidteren.github.io/current_scope/quickstart.html) and in
the install generator's next-steps text (#25). **Existing apps with traffic
must use [report mode first](#retrofitting-an-app-that-already-has-users)**
before bootstrap — do not cut over blind.

```ruby
# Gemfile
gem "current_scope"
```

```bash
bin/rails generate current_scope:install
bin/rails current_scope:install:migrations && bin/rails db:migrate
```

**1. Include the concerns** in `ApplicationController` — `Context` populates
the ambient subject from your authentication, `Guard` gates every action:

```ruby
class ApplicationController < ActionController::Base
  include CurrentScope::Context   # sets CurrentScope::Current.user from current_user
  include CurrentScope::Guard     # fail-closed gate on every action
end
```

**2. Skip the gate on sign-in** (and other public endpoints). **Do not skip
this step** — the gate is fail-closed and covers *everything*, including login.
Prefer the declared form so the role grid shows **why** the gate is off:

```ruby
class SessionsController < ApplicationController
  current_scope_skip_gate!(reason: "sign-in must run without a grant")
  # While impersonating, sign-in/out must also clear the mutation guard or a
  # POST that ends act-as is blocked (same as bare skip of the permission gate):
  skip_before_action :current_scope_mutation_guard!
  # bare skip_before_action :current_scope_check! still works, but the grid
  # marks it as an unexplained "gate not run"
end
```

A skipped controller is unprotected by the permission gate — supply your own
auth where that matters ([security checklist](docs/SECURITY-CHECKLIST.md)).

**3. Bootstrap the first admin.** The management UI only admits full-access
subjects; the seeded **Member** role starts with **zero** permissions until
you edit it:

```bash
bin/rails current_scope:grant SUBJECT_ID=YOUR_USER_ID
# or: CurrentScope.grant!(User.first)   # upserts Owner — not RoleAssignment.create!
```

`grant!` reuses an existing role named Owner without forcing `full_access`.
On a greenfield seed that is fine (seed_defaults! creates Owner as full_access).
If someone renamed/stripped Owner earlier, repair with
`CurrentScope::Role.find_by!(name: "Owner").update!(full_access: true)` before
expecting `/current_scope` to open.

**4. Manage roles** at `/current_scope`. A Guard denial is HTTP 403 with
`X-Current-Scope-Reason` (`no_grant`, `sod_veto`, …) when the default
engine rescue runs. Host `rescue_from` handlers can replace that response.

To copy a role grid between environments, export YAML and apply it with a
confirm flag. See [Portable role definitions](docs/guides/role-definitions.md).
Assignments are not in that document.

### Retrofitting an app that already has users

> **Retrofitting a real app?** There's a full guide:
> [Adopting CurrentScope in an existing app](docs/guides/adopting-in-an-existing-app.md)
> — callback ordering vs. your authentication, the Devise recipe, the
> `skip_before_action` fail-open trap, hybrid HTML+API grants, and a rollout
> ladder. The short version is below.
>
> **Shipping?** Read the [Security & production checklist](docs/SECURITY-CHECKLIST.md)
> first — excluded controllers, the 403/404 record oracle, and the pre-ship tick list.


The gate is fail-closed, so the line you just added denies **everything** until
grants exist. On a greenfield app that's invisible — you seed the Owner role and
move on. On an app that already has controllers and traffic, it means your suite
goes red and your users get 403s the moment you deploy, and the only way to
discover what you should have granted is to break it and read the wreckage.

Don't cut over blind. Run in report mode first:

```ruby
CurrentScope.configure do |config|
  config.enforcement = :report   # :enforce (default) | :report
end
```

The gate now logs what it *would* have denied and lets the request through,
recording each one to the ledger. Exercise the app, or just run your suite —
then read the gaps back out:

```bash
bin/rails current_scope:report
```

```
Would-be denials still outstanding — grant these to stop them (most-denied first):

  Ada Lovelace — currently Member
      412x  reports#index
       38x  reports#export
  Grace Hopper
        7x  reports#approve

Total: 457 outstanding would-be denial(s) across 2 subject(s).
```

That *is* your grant-seeding work, in the shape of the role grid you need to
build: every subject who'd have been refused, what they were missing, and how
badly. Seed the roles it names, re-exercise, and flip to `:enforce` once newly
exercised requests stop adding rows (the report reads the append-only
ledger, so historical rows do not clear). Each step is one line back, and nobody gets a 403 while you learn.

The rows are ordinary ledger events, so query them directly if you want
something the task doesn't show:

```ruby
CurrentScope::Event.where(event: "access.would_deny").pluck(:subject, :details)
# => [["gid://app/User/7", {"permission" => "reports#index", "reason" => "no_grant"}], ...]
```

**Report mode is an adoption ramp, not an off switch — don't run production on
it.** It relaxes exactly one denial: *nobody has granted this yet*. Everything
else still refuses:

| Still enforced in `:report` | Why it can't be relaxed |
|---|---|
| Separation-of-duties veto | Lifting it lets an initiator really approve their own record — a fraud action executed, not a role gap surfaced. |
| SoD actions the veto *couldn't* run on | If an SoD action is gated without a record, the veto has no initiator to measure and is skipped — so the refusal that comes back says "not granted", not "SoD approved". Report mode won't speak for a rule nobody asked, and still refuses — but it **logs the blind spot and records `access.sod_blind_spot`** (not `access.would_deny`; granting will not clear the 403). `rails current_scope:report` lists them separately. |
| SoD actions on a model with no `current_scope_initiator` | The veto cannot be measured at all, so the resolver raises `ConfigurationError` and the request **500s — under `:report` exactly as under `:enforce`**. Passing it through would run a four-eyes action unchecked; a 403 would make a wiring mistake read as an ordinary denial. The engine warns about these **when the routes load** (boot in production and staging; development's lazy route set defers it to the first request) where a controller declares `current_scope_model`, records `access.sod_initiator_missing` when traffic finds one, and `rails current_scope:report` lists both. |
| The management console | It's where grants are made. An observation flag that opened it would be a privilege escalation. |
| Impersonation read-only gate | Runs before the permission check and answers to its own rule. |

The response carries `X-Current-Scope-Reason: would_deny` on anything report mode
let through, so you can spot them in an integration test or a proxy log without
reading the ledger.

**Assumption #1: every controller descends from a `Guard`'d base.** An action on
a controller that never includes `Guard` (an API base, a hand-rolled
`ActionController::Base`) is silently ungated — though no longer invisibly: the
permission grid badges any controller **provably** ungated ("gate not run"),
and `bin/rails current_scope:ungated` prints the same inventory as a command.
To catch it at runtime, include the optional `CurrentScope::GatingTripwire` on
the base you want verified — it fires after any action that didn't run the
gate: **raising in dev/test, or logging once per `controller#action` under
`config.gating_tripwire = :warn` (the default outside dev/test; once per
process per site — a concurrent first hit can rarely emit a duplicate line)**, so a
production host can inventory its ungated surface without 500ing. It carries
its own `current_scope_skip_tripwire!` marker for genuinely-public actions (you
can't use `skip_before_action :current_scope_check!` on a controller that never
defined that callback — it raises at class load):

```ruby
class ApiController < ActionController::Base
  include CurrentScope::GatingTripwire
  current_scope_skip_tripwire! only: :health
end
```

It's an `after_action`, so it can't see an action that renders from a
`before_action` (halted chain) — a strong aid, not total coverage. The grid
badge and the `ungated` task mark only what the callback chain *proves*: a
conditional skip (`only:`/`except:`) renders unmarked and is exactly what
`:warn` exists to catch.

Bootstrap the first admin (the management UI needs a full-access subject to
enter, so the first grant can't happen in the UI). One command:

```bash
bin/rails current_scope:grant SUBJECT_ID=1   # grants the full-access Owner role
```

To attach by a portable key (email, or a composite) instead of the raw id,
set `config.subject_identity` and run `current_scope:identity:setup`. That
knob is not `config.subject_label`. `CurrentScope.identify_subject(record)`
returns that portable key and `CurrentScope.resolve_subject(key)` returns the
record for it in this environment. See the
[adoption guide](docs/guides/adopting-in-an-existing-app.md#declare-how-a-subject-is-identified).

Or in `db/seeds.rb`:

```ruby
CurrentScope.seed_defaults!            # Owner (full_access) + Member
CurrentScope.grant!(User.first)        # give the first user the Owner role
```

Then manage everything at `/current_scope` (full-access subjects only): the
role grid, org-wide assignments, scoped grants.

## Documentation

| Guide | What it covers |
|---|---|
| [Concepts & glossary](docs/guides/concepts-and-glossary.md) | Decision order + core vocabulary — **read first** |
| [Checking permissions](docs/guides/checking-permissions.md) | `allowed_to?`, `scope_for`, record-level, scopeable models |
| [Separation of duties & break-glass](docs/guides/separation-of-duties-and-break-glass.md) | SoD veto, `allow_sod_bypass` |
| [Impersonation](docs/guides/impersonation.md) | Act-as, mutation guard, denial shape |
| [Configuration reference](docs/guides/configuration-reference.md) | Initializer knobs, enforcement, audit, diagnostics |
| [Testing](docs/guides/testing.md) | `TestHelpers`, grants in request specs |
| [Adopting in an existing app](docs/guides/adopting-in-an-existing-app.md) | Report-mode retrofit ladder |
| [Security & production checklist](docs/SECURITY-CHECKLIST.md) | Pre-ship tick list |
| [Is it the right fit?](https://davidteren.github.io/current_scope/comparison.html) | CurrentScope vs Pundit, Action Policy, CanCanCan, Banken, Oso — and adoption cost |
| [Docs site](https://davidteren.github.io/current_scope/) | Published quickstart, SoD story, AI-agent prompts |

Root [CONCEPTS.md](CONCEPTS.md) is the longer glossary narrative for maintainers.

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

## Limitations

**SSR-first.** CurrentScope is for server-rendered Rails (controllers, views,
ViewComponents, Turbo). Separate JS front-ends ([#96](https://github.com/davidteren/current_scope/issues/96))
and Inertia ([#97](https://github.com/davidteren/current_scope/issues/97)) have
no first-class client contract yet. API controllers that include Guard still
authorize on the server.

**Model limits** — deliberate shape of the v1 data model, not gaps:

| Limit | What it means |
|---|---|
| **Flat scoped grants (default)** | Flat unless the child declares `current_scope_parent`. Then the chain is bounded at five hops, and a scoped `full_access` grant does not cascade. See [Checking permissions](docs/guides/checking-permissions.md#a-grant-on-a-parent-record-108). |
| **One org-wide role** | At most one org-wide role per subject (DB-enforced). |
| **Scoped role = full bundle** | Scoping reuses the whole role; there is no per-record capability subset. |

**Intentional residuals** (not forgotten bugs) — full write-up on the
[Limitations page](https://davidteren.github.io/current_scope/limitations.html)
(source: [docs/site/limitations.md](docs/site/limitations.md)):

| Residual | What it means for you |
|---|---|
| A5 SoD + nil record | Member SoD actions must return the record or the veto is skipped |
| A2 `actor_method` | Set it when you impersonate; no false auto-detect |
| A6 audit degrade | Use `audit: :strict` when the ledger is mandatory |
| Trusted `current_scope_model` | Wrong type can open wrong listed reads — review like the record hook |
| Report × model_undeclared / model_invalid | Hard 403 (reason header + dev nudge) only when a scoped grant would otherwise satisfy; plain no_grant still report-mode observes |
| GatingTripwire opt-in | Never-included Guard stays open; include Guard + optional tripwire |
| Parent/child cascade is opt-in | Flat unless the child declares `current_scope_parent`; then bounded at 5 hops, and `full_access` does not cascade (#108) |

If any of these rules CurrentScope out for you, the
[fit comparison](https://davidteren.github.io/current_scope/comparison.html)
names which of Pundit, Action Policy, CanCanCan, Banken or Oso to read next.

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
