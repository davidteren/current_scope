# Checking permissions

> See also: [Concepts & glossary](concepts-and-glossary.md).

## Checking permissions — anywhere

`allowed_to?` is available in controllers and views via `Context`, and in any
PORO or ViewComponent by mixing in `CurrentScope::Permissions`. No
`current_user` threading, ever:

```ruby
allowed_to?(:approve, report)         # key derived from the record → reports#approve
allowed_to?(:create, Report)          # class form for collection actions
allowed_to?("admin/reports#approve")  # explicit key when you need it
```

Key derivation agrees with the gate **when the current controller's path ends
in the record's route key**: inside `Admin::ReportsController` (path
`admin/reports`, route key `reports`), `allowed_to?(:approve, report)` resolves
to `admin/reports#approve` — exactly what the Guard enforces there — and a
cross-resource check from a projects view resolves to `reports#approve`.

> **Residual foot-gun — namespaced/custom-named controllers.** When a
> controller's path segment differs from the record's route key (e.g. a
> `DashboardController` that renders `Report`s: path `dashboard`, route key
> `reports`), the short-form `allowed_to?(:show, report)` derives
> `reports#show` while the Guard enforces `dashboard#show` — so a link may show
> that then 403s (or hide that would work). The Guard stays authoritative, so
> this is a display bug, not a bypass. **In such controllers, prefer the
> explicit full key** — `allowed_to?("dashboard#show")` — which removes the
> ambiguity. The short form is only guaranteed to match the gate when path
> segment == route key.

```ruby
class ApproveButtonComponent < ViewComponent::Base
  include CurrentScope::Permissions

  def render? = !report.approved? && allowed_to?(:approve, report)
end
```

## Scoping a list (`scope_for`)

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

private

# A collection-only controller declares BOTH hooks. current_scope_record = nil
# is what tells the gate "this action has no record" (a scoped grant can then
# open it); WITHOUT it the gate assumes nothing and current_scope_model is
# inert — the grant never opens the gate. current_scope_model then names the
# TYPE, so the grant opens the record-less gate only for Projects. (A
# controller with member actions already has current_scope_record; it just
# adds current_scope_model.)
def current_scope_record = nil
def current_scope_model = Project
```

- **full-access or an org-wide grant** of the key → every record (`Project.all`).
- **scoped grants** → only the specific records that role was granted on.
- **no grant** (or no subject) → empty, fail-closed like the gate.

The gate agrees. A collection action like `#index` has no record to name, so it
asks a record-less question, bound to the type the controller declares
(`current_scope_model`, above). For a **collection read**
(`config.collection_read_actions`, `index` by default) the gate asks
`scope_for` itself: the subject reaches the list exactly when it would show
them records — scoped `full_access` grants included — and the two halves
cannot disagree, because they are one query. Any other record-less key needs a
scoped grant whose role ticks it explicitly; `scope_for` then narrows the list
to the records they were actually granted. A grant on a `Report` never opens a
`Projects` gate — the type is what binds them. **No org-wide grant is needed to
reach a scoped index** (and reaching for one would defeat the purpose — an
org-wide grant means "see everything", so `scope_for` would return
`Project.all`). The same holds for the class form,
`allowed_to?(:index, Project)`, which carries the type as its argument, so a
view helper and the gate never disagree. A controller that does **not** declare
`current_scope_model` fails the record-less gate closed for scoped grants (the
denial carries `X-Current-Scope-Reason: model_undeclared`, and a dev nudge
names the one-line fix). A declaration that returns something other than a
concrete ActiveRecord class — `"Report"` for `Report`, say — also fails
closed, labelled `model_invalid`, with a nudge naming the value the hook
returned.

> **The gate admits; `scope_for` narrows. Both halves are yours to wire.** The
> gate only decides *whether* `#index` runs — it cannot filter a list you build
> with `Project.all`. If a scoped role ticks a collection key and that action
> doesn't call `scope_for`, the subject reaches the action and sees everything
> it queries. Gate a collection action for scoped roles only alongside a
> `scope_for` list.

Off the read list the rule is uniform: a scoped role that ticks `create` or a
bulk key opens *those* collection gates too, exactly as an org-wide grant of
the same key already does. Tick a collection key on a scoped role only when
you mean it — there is no record filter on `create`.

A scoped **`full_access`** role follows the read/write split: it opens the
listed reads of its record's type — the gate derives from which records the
grant actually holds, so "Owner of Project #7" reaches the project index and
sees Project #7 — and nothing else record-less. A full_access role satisfies
*every* key, so honoring it in a record-less check that answers with a bare
boolean would make one scoped grant a pass on every `#create` in the app; the
read gates are safe precisely because their answer comes from the list. Two
consequences worth knowing: a grant whose record is absent from the model's
default scope — destroyed, soft-deleted, or scoped out by a tenant
`default_scope` — opens nothing (an empty list is a 403, not an empty page),
and the declared
`current_scope_model` is **trusted like the record hook** — a wrong
declaration opens that controller's listed reads to full_access holders of the
declared type, so review the declaration the way you review
`current_scope_record`.

It returns a chainable `ActiveRecord::Relation`, so `.where`/`.order`/`.page`
compose normally. `permission:` defaults to the model's `index` key and accepts
a bare action or a full key (`scope_for(Report, permission: :approve)`).

Every record `scope_for(Project)` returns passes `allowed_to?(:index, project)`,
and every record it omits fails it — by construction, not by convention. It
resolves against the **effective** subject, so acting-as changes what lists
show, and it is **flat**: a scoped grant lists that record only (parent/child
cascade is deferred). SoD does not apply — it vetoes record-targeted *actions*,
not list membership.

## Record-level decisions

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

The same hook has two foot-guns worth knowing before you ship: returning **nil**
on an SoD member action silently skips the veto
([Separation of duties](separation-of-duties-and-break-glass.md)), and loading with
`Model.find` means an unauthorized caller sees **403** for an existing id vs
**404** for a missing one — a record-existence oracle
([security checklist mitigation](../SECURITY-CHECKLIST.md#2-403-vs-404-leaks-which-records-exist)).

## Scopeable models

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
