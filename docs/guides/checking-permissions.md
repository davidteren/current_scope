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

> **Residual foot-gun — `allowed_to?` never consults the catalog.** The Guard
> raises if you gate an uncataloged key. Advisory `allowed_to?` does not: a
> typo (`allowed_to?("reprots#show")`) is a silent false (button never shows);
> a raw grant row for a removed route can make `allowed_to?` true for a key the
> gate will never see. Fail-closed either way, but a debugging wall. Prefer
> keys that appear in the permission grid; treat the Guard as authoritative.
> (#36)

```ruby
class ApproveButtonComponent < ViewComponent::Base
  include CurrentScope::Permissions

  def render? = !report.approved? && allowed_to?(:approve, report)
end
```

## Scoping a list (`scope_for`)

`allowed_to?` answers "may I act on **this** record?". `scope_for` answers the
list-side question — "**which** records may I act on?" — from the *same* roles,
permissions, and scoped grants the gate reads. Both sides key grants on
`polymorphic_name` (the stored token), so a custom type name cannot pass the
record check and miss the list. Use it for index pages so the list and the
per-record gate stay one source of truth, never a hand-written query that
drifts:

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
- **scoped grants** → only the specific records that role was granted on, plus
  the children of granted parents when the model declares a chain (below).
- **no grant** (or no subject) → empty, fail-closed like the gate.

### A grant on a parent record (#108)

Scoping is flat by default: a role held on `Project 7` matches actions on
`Project 7` and nothing else. Opt a model in when authority should reach down a
level:

```ruby
class Report < ApplicationRecord
  belongs_to :project
  current_scope_parent :project

  # Unchanged, and it still names the REPORT's requester.
  def current_scope_initiator = requested_by
end
```

Now a scoped role held on `Project 7` satisfies `reports#approve` on that
project's reports, including reports created after the grant, and
`scope_for(Report)` lists exactly those reports.

Three things to know before you declare one.

**A scoped `full_access` grant does not cascade.** Only roles that explicitly
tick the key reach children. A scoped `full_access` grant on a root record would
otherwise open every permission on everything beneath it, which is a much larger
grant than the operator who ticked one box intended. The side effect is that
privilege stops being monotonic here: a `full_access` role reaches *fewer*
records through a chain than a role that merely ticks the key. If you want
blanket authority over a subtree, tick the keys.

**The four-eyes veto still reads the record you handed back**, never an ancestor.
A lead holding a grant on `Project 7` still cannot approve a report they
requested themselves. This is the whole reason the chain feeds grant matching
only — the older workaround, handing the *parent* back from
`current_scope_record` so the grant would match, moved the record the veto reads
and silently blinded it.

**It is a class macro, not a method.** Every other `current_scope_*` hook is a
plain method you define. This one names an association instead, because
`scope_for` has to build a query from the foreign key and a method returning a
parent instance cannot give it one. Writing `def current_scope_parent = project`
raises rather than being ignored.

**Declaration errors raise; data never does.** A missing association, a
`has_many`, a polymorphic or scoped `belongs_to`, or a declaration on an STI
subclass all raise `ConfigurationError` at the macro with the fix named. A
custom association primary key is refused later by
`ParentChain.validate_declarations!` (on `to_prepare`, plus after initialize
when `config.eager_load` is true), because the check needs `reflection.klass`
and resolving that inside the macro breaks ordinary forward references — see
[UPGRADING.md](../../UPGRADING.md) for when that pass does and does not see a
model. The *shape of your rows* is not a misconfiguration: a chain longer than
five hops, or a `parent_id` loop, stops the walk where it runs out, **denies**,
and logs one warning per model. It never raises, because a loop in the data is
two `UPDATE`s and must not turn a live request into a 500. If a subject is
missing access they should have, look for "current_scope_parent stopped walking"
in the log.

### When a scoped grant reaches nothing

`bin/rails current_scope:report` and the role members view flag two shapes
before you flip `config.enforcement` to `:enforce`:

- **cannot match** — proven. The role ticks no permissions, or only keys that no
  route produces. Tick a key, or remove the grant.
- **check hooks** — advisory. No ticked key names a controller for the grant's
  record type. The engine cannot prove this (`current_scope_record` runs at
  request time), so a controller serving that type under another name is a false
  alarm. Read the hook before removing anything.

Neither is the same as **inert** (a grant whose record was deleted), which has a
third fix: remove the grant. See [Limitations A16](../site/limitations.md).

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
show. A scoped grant lists that record only — plus the descendants of granted
records when the model declares `current_scope_parent` (see above). SoD does not
apply — it vetoes record-targeted *actions*,
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
in, and once a record of such a type is linked the console will list that type's
records too, so a full-access operator can browse a table you never registered;
the mixin only decides what shows up in the dropdown unprompted. `current_scope_label`
is a plain instance method, so your own definition always wins over the default.

### Which roles may be granted on a type (#183)

A role's permission bundle is written for one **shape** of record. When that
record declares a `current_scope_parent`, a grant held on the CONTAINER resolves
for every record inside it — so granting a per-record role on the container hands
the subject that per-record surface across the whole container. One wrong pick in
a dropdown, and by default nothing objects.

A type can say what it accepts:

```ruby
class Workstream < ApplicationRecord
  include CurrentScope::Scopeable
  self.current_scope_grantable_roles = %w[Lead]
end
```

- **Absent a declaration nothing changes**: every role stays grantable on every
  type. Opting in is per type.
- The rule is enforced on the **model**, so a seed, a rake task and a console
  one-liner meet it as well as the management UI. It is a validation, so the
  write paths that skip validations skip it too: `insert_all`, `upsert_all`,
  `update_column` and `update_columns` write whatever they are given, and no
  database constraint stands behind them. The picker narrows the type dropdown
  to those that accept the chosen role, and says how many it withheld.
- An **empty** declaration, `self.current_scope_grantable_roles = []`, means no
  role may be granted on that type. It is an assignment rather than a DSL call
  precisely so a computed empty list declares the lockdown instead of silently
  reading the current value. Assigning **`nil`** is the opposite: it means no
  declaration, so a list read from config with a missing key leaves the type as
  it was rather than locking it. "As it was" means the accept-everything default
  on a plain class, and the **parent's** declaration on a subclass, which is the
  next bullet's inheritance rule: `SpecialInvoice.current_scope_grantable_roles
  = nil` under a locked-down base inherits that lockdown. Mind the difference when you compute
  the list: `ENV.fetch("CS_ROLES", "").split(",")` is `[]` with the variable
  unset, which is a lockdown, and that is the fail-closed answer. Assign `nil`
  when you mean "no declaration".
- A subclass inherits its parent's declaration until it states its own, and an
  **STI subclass** is governed by its own declaration even though the grant row
  stores the base class's token. That needs the record: when the row it names is
  gone, or its stored id is not a canonical key for the model, the check has
  only the stored token to go on and judges the grant by the **base class**. One table therefore holds records with
  different answers, so the picker keeps every class over an STI table in the
  type dropdown and narrows the **record** list instead. How far the picker READS
  is decided from `descendants`, which sees only loaded classes: in an
  environment that does not eager-load, a declaring subclass nothing has
  referenced yet can leave a grantable record past the display cut until the
  next request, and production eager-loading closes it. What the picker SAYS is
  decided from the rows instead, because a message that is wrong is worse than a
  fetch that is narrow.
- `CurrentScope::GrantableRoles` can be included on its own if you want the rule
  without the picker registration.

**Roles are matched by NAME**, and that is the trade a declaration written in
code makes: role ids are per-database and cannot be named in a model file. So
renaming a role stops the declarations that name it from matching, and a new role
that reuses the name inherits its acceptance. If you rename a role, grep for its
old name in your models, and run `bin/rails current_scope:report`: it lists the
grants whose type would refuse them today, which is where a rename shows up.

Adding a declaration does not rewrite or delete any grant already in the table.
It does apply the next time such a row is **saved**, though: the check runs on
every write, not only on create, so a pre-existing pairing the new declaration
refuses will fail validation if host code saves that row again. That is
deliberate. `assignment.update!(role: other_role)` has to meet the same rule as
the grant that created it, or the console's gate would be one `update` wide.
