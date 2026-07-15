# Grantwork Engine — Design Concept

> **Status:** design-concept capture. This document describes a mechanism and
> positions it against known patterns. It is *not* a finished spec — open
> questions are surfaced, not solved.
>
> **Gem name:** TBD. All code examples are namespaced under a placeholder
> module `Grantwork`.

---

## 1. What it is

**Grantwork is a Rails authorization engine delivered the way Devise delivers
authentication: a mountable engine + generators + scaffolded management UI.**
You add the gem, run an install generator, get migrations, models, a resolver,
a policy integration, and a set of generated management views. From there,
authorization is *data you edit in the UI* rather than rules you hardcode and
redeploy.

The core idea: **every controller action in your app is automatically a
grantable permission.** A **role** is a named, editable bundle of those
permissions (a saved set of checkboxes on a controller × action grid). A user
holds exactly one org-wide role, plus zero-or-more **scoped roles** attached to
specific records ("Editor of Project X"). A single **resolver** answers every
"can this subject do this action (on this record)?" question, fail-closed, with
a non-negotiable Separation-of-Duties veto layered on top.

> **The Devise analogy is about *delivery*, not domain.** Devise is
> authentication (proving *who* you are). Grantwork is authorization (deciding
> *what* you may do). What they share is the shape: an engine you mount,
> generators that scaffold the wiring and the UI, and models you own in your
> host app.

---

## 2. Glossary

| Term | Definition |
|---|---|
| **Authentication (AuthN)** | Proving *who* the subject is — "auth-in", logging in. Establishes identity. **Out of scope for this engine.** |
| **Authorization (AuthZ)** | Deciding *what* an authenticated subject may do — "auth-to". This engine's entire concern. |
| **Subject** | The actor whose permissions are being checked — typically a `User`. Holds one org-wide role and zero-or-more scoped roles. |
| **Resource** | A thing an action targets. Two senses: the *controller/resource-type* (e.g. `reports`) and a *specific record* (e.g. Report #42). Scoped roles attach to a specific record. |
| **Action** | A single `controller#action` pair (e.g. `reports#show`, `reports#approve`). The atomic unit of permission. |
| **Permission** | The right to perform one action. Auto-derived from the app's controllers/routes — there is one permission per `controller#action`. |
| **Role** | A named, editable bundle of permissions (data, not code). A row with a unique name plus the set of permissions it grants. |
| **Scoped role** | The same Role concept, attached to *one specific record* (polymorphic). Its permissions apply only when acting on that record. |
| **Policy** | Host-app enforcement object (Pundit/ActionPolicy style) whose predicates delegate to the resolver. The place a request is actually allowed or blocked. |
| **PEP — Policy Enforcement Point** | *Where* the decision is enforced. Here: the host policy layer + a controller concern. Blocks the request. |
| **PDP — Policy Decision Point** | *What* makes the decision. Here: the resolver. Answers allow/deny. |
| **PAP — Policy Administration Point** | *Where* rules are authored/edited. Here: the scaffolded management UI (role editor, grid, assignments). |
| **PIP — Policy Information Point** | *Where* the data behind a decision lives. Here: the roles/permissions/assignments tables (in your DB). |
| **SoD — Separation of Duties** | Also called the **"four-eyes" principle**. A control requiring that a sensitive operation involve at least two distinct people: whoever *initiates/requests* a record cannot be the one who *approves* it. In this engine it is a **non-configurable veto** (see §3.6). |
| **Default-deny / fail-closed** | Absence of an explicit grant means denied. No role and no scoped grant → denied. Nothing is implicitly allowed. |

---

## 3. Core mechanism

### 3.1 Permissions are controller actions (auto-derived)

There is no separate permission vocabulary to maintain. **The set of permissions
*is* the set of `controller#action` pairs in your app**, derived automatically
from the router/controllers.

```
GET    /reports            reports#index      ← permission: reports#index
GET    /reports/:id        reports#show       ← permission: reports#show
GET    /reports/new        reports#new        ← permission: reports#new
POST   /reports            reports#create     ← permission: reports#create
GET    /reports/:id/edit   reports#edit       ← permission: reports#edit
PATCH  /reports/:id        reports#update     ← permission: reports#update
DELETE /reports/:id        reports#destroy    ← permission: reports#destroy
POST   /reports/:id/approve reports#approve   ← permission: reports#approve  (custom member action)
```

This is exactly how a role can "view but not destroy" (grant `show`/`index`,
withhold `destroy`) or "create but not approve" (grant `create`, withhold
`approve`). The grain is the action.

**New controllers auto-appear as new permissions with zero wiring.** Add an
`OrdersController` with the usual REST actions and — because permissions are
derived from the router — seven new permissions (`orders#index` … `orders#destroy`)
show up in the grid automatically. Nothing to register, no migration.

**Considerations (not solved here):**
- **Namespaces** (`admin/reports#index`) — the permission key must include the
  namespace so `Admin::ReportsController` and `ReportsController` don't collide.
- **Mounted engines** — controllers from other mounted engines may or may not
  be in scope; needs a declared include/exclude policy (see §9).
- **Non-RESTful / infrastructure actions** — health checks, callbacks, webhooks
  probably should be excludable from the grid.

### 3.2 Roles are data (a named permission bundle)

A role is a **row**, not a class:

```
Role(name: "Reviewer", full_access: false)
  └─ permissions: { reports#index, reports#show, reports#approve }
```

Roles are **seeded and then editable in the UI** — a director/admin ticks cells
on the controller × action grid and saves. No redeploy to change what "Reviewer"
means.

**A subject holds exactly one org-wide role.** (This is a deliberate choice;
the multi-role alternative is noted in §9.)

### 3.3 `full_access` flag = superuser

A role may set `full_access: true`. This **auto-grants every permission,
including permissions added by future controllers.**

Why a flag instead of "just tick every box"? Because a role with every *current*
box ticked would **silently miss** the permissions introduced by the next
controller someone adds. The flag means "everything, present and future" — the
correct model for an `Owner`.

```
Role(name: "Owner", full_access: true)   # grants all current + future permissions
```

### 3.4 Scoped roles (relationship-based)

A **scoped role is the same Role concept attached to one specific record** via a
polymorphic association. A subject holds **zero-to-many** scoped roles, of
different roles on different records:

```
"Editor of Project #7"       → Role(Editor)   on Project #7
"Reviewer of Report #42"     → Role(Reviewer) on Report #42
```

Its permissions apply **only when the action targets that record.** Being
"Editor of Project #7" grants nothing on Project #8.

The one qualifier: a **record-less** check — a collection action like `#index`,
which reaches the resolver with no record, or the class form
`allowed_to?(:index, Project)` — names no record for the grant to be measured
against. There, any scoped grant whose role ticks the key opens the gate, and
`scope_for` narrows the resulting list to the granted records. This is what lets
"Editor of Project #7" reach a project index at all without an org-wide grant
(which would mean *see everything*). It never widens a decision on an actual
record: Project #8 is still denied.

This is uniform across record-less actions rather than special-cased to
`#index`: a scoped role ticking `create` or a bulk key opens those gates too,
as an org-wide grant of that key already does. The role author's ticks are the
control — a record-less action has no record to filter on either way. The
target shape is a closed set (`nil` or a `Class`); anything else is not
record-less and is denied, so a hook that returns something other than a record
fails closed.

**Assigning a scoped role NEVER changes the subject's org-wide role.** The two
are independent axes: one org-wide role (broad, coarse) + N scoped roles
(narrow, per-record).

### 3.5 Default-deny / fail-closed

No org-wide grant and no scoped grant for a permission → **denied.** There are no
implicit abilities. **"Everything is a permission"** — even the baseline things
every logged-in user can do are permissions carried by a baseline role (e.g. a
`Member` role assigned to everyone by default). If you want authenticated users
to see their dashboard, `dashboard#show` is a permission on the `Member` role,
not a special case in code.

### 3.6 Separation of Duties (SoD) — the veto

**SoD (Separation of Duties, a.k.a. the "four-eyes" principle)** is a
**non-configurable constraint: the subject who initiated/requested a record can
never be the subject who approves it.** Example: *whoever submits a report
cannot approve it*; *the author of a document cannot approve it*.

Key properties:
- It is a **VETO, not a grantable permission.** You cannot tick a box to opt out.
- It **overrides every role, including `full_access`.** An Owner who authored
  the document still cannot approve their own document.
- It **runs FIRST**, before any role is consulted.

**Why it lives outside the editable rules:** the whole point of SoD is that it
*cannot* be granted away. If it were an editable permission, an admin (or a
compromised account with `full_access`) could simply switch it off — defeating
the control. It is a structural guarantee, not a preference, so it is enforced
in code and sits above the data-driven layer.

### 3.7 The resolver (PDP) — decision order

One resolver answers every check, in this fixed order:

```
resolve(subject, permission, record = nil):
  1. SoD veto        → if this is an approve-style action on `record`
                        AND subject initiated `record`  → DENY   (overrides all)
  2. full_access     → if subject's org-wide role.full_access?  → ALLOW
  3. org-wide role   → if subject's org-wide role includes `permission` → ALLOW
  4. scoped role     → if subject holds a scoped role on THIS `record`
                        whose role includes `permission`  → ALLOW
  5. otherwise       → DENY   (default-deny)
```

```ruby
module Grantwork
  class Resolver
    def allow?(subject:, permission:, record: nil)
      return false if Sod.veto?(subject:, permission:, record:)   # 1
      role = subject.grantwork_role
      return true if role&.full_access?                            # 2
      return true if role&.grants?(permission)                     # 3
      return true if scoped_grant?(subject:, permission:, record:) # 4
      false                                                        # 5
    end

    private

    def scoped_grant?(subject:, permission:, record:)
      return false if record.nil?
      subject.grantwork_scoped_roles
             .on(record)
             .any? { |sr| sr.role.grants?(permission) }
    end
  end
end
```

---

## 4. The distinctive part: elegant resource attachment

The interesting design move is how a role attaches to **a specific record** and
how the resolver answers *"does this subject hold a scoped role on THIS record
that grants this action?"*

A scoped-role assignment is a join row with a polymorphic target:

```
ScopedRoleAssignment(subject: user, role: Role(Editor),
                     resource_type: "Project", resource_id: 7)
```

Resolution for step (4) is a scoped lookup:

```ruby
subject.grantwork_scoped_roles
       .where(resource_type: record.class.name, resource_id: record.id)
       .any? { |sr| sr.role.grants?(permission) }
```

Because the scoped role reuses the *same* Role rows as org-wide roles, "Editor"
means the same set of permissions whether held org-wide or on one record — only
the *reach* differs.

**Open question — resource hierarchy / cascade (NOT solved here):** should a
scoped role on a *parent* apply to its *children*? E.g. "Editor of Project #7"
implying edit rights on the reports that belong to Project #7. This engine as
described resolves against *the record itself* only. Cascade would require a
declared parent/child traversal (and raises questions about depth, performance,
and cycles). Flagged for iteration — see §9.

---

## 5. RESTful action rights in detail

Each of the 7 standard REST actions maps to a concrete capability; custom
actions extend the set. A role's grid row expresses which it holds.

| Action | HTTP | Granting it means | Denying it means |
|---|---|---|---|
| `index` | `GET /reports` | Can **list** reports | Cannot see the list |
| `show` | `GET /reports/:id` | Can **view** one report | Cannot open a report |
| `new` | `GET /reports/new` | Can see the **create form** | No create form |
| `create` | `POST /reports` | Can **create** a report | Cannot create |
| `edit` | `GET /reports/:id/edit` | Can see the **edit form** | No edit form |
| `update` | `PATCH /reports/:id` | Can **modify** a report | Cannot modify |
| `destroy` | `DELETE /reports/:id` | Can **delete** a report | Cannot delete |
| custom, e.g. `approve` | `POST /reports/:id/approve` | Can perform the **custom operation** | Cannot perform it |

**How the grid expresses "can X, can't Y":** the role editor renders one row per
controller, one column per action. "Can view but not destroy" = `index` and
`show` ticked, `destroy` unticked. "Can create but not approve" = `create`
ticked, `approve` unticked. Ticking the whole row = every action on that
controller; the `full_access` toggle = every action on every controller (now and
future).

```
                index  show  new  create  edit  update  destroy  approve
reports           ✓     ✓    ✓     ✓       ✓     ✓        ☐        ☐     ← Editor: everything but destroy/approve
```

---

## 6. How this differs from / relates to known patterns

This engine is a **composition**, not a brand-new named pattern. It combines
data-driven RBAC + ReBAC-style scoped roles + action-level permissions + an SoD
veto + Devise-style generators. Below, honest positioning.

### 6.1 Against access-control models

| Model | What it is | Relationship to this engine |
|---|---|---|
| **RBAC** (Role-Based Access Control) | Permissions grouped into roles, roles assigned to subjects. | **This is RBAC — specifically *data-driven* RBAC:** roles and their permission sets are editable rows, not hardcoded constants. |
| **Hierarchical RBAC** | Roles arranged in a tier ladder; senior roles inherit juniors' permissions. | **This deliberately AVOIDS the tier ladder.** Instead of inheritance it uses (a) flat data roles, (b) a `full_access` flag for the superuser case, and (c) scoped roles for the "senior on *this* thing" case. No implicit inheritance to reason about. |
| **ABAC** (Attribute-Based Access Control) | Decisions from attributes of subject/resource/environment (time, department, status). | **Not ABAC.** This engine keys off *roles* and *record identity*, not arbitrary attributes. The SoD veto is the one attribute-ish rule (who initiated the record), enforced structurally rather than as a general attribute engine. |
| **PBAC** (Policy-Based Access Control) | Rules/policies as editable, centrally-managed data. | **Partial overlap:** permissions and role bundles are editable data (a PAP in the UI). But rules are role-membership + record-relationship, not a general policy language. |
| **ReBAC** (Relationship-Based Access Control) | Access from relationships between subject and resource ("editor of this doc"). | **The scoped-role feature IS ReBAC:** "Editor of Project #7" is exactly a subject→resource relationship. The difference from Zanzibar/OpenFGA is scale and locality (below). |

### 6.2 Against Zanzibar / OpenFGA

Google Zanzibar (and its open-source lineage, **OpenFGA**, **SpiceDB**) model
authorization as a globally-distributed graph of relationship tuples
(`user:anne editor doc:42`) resolved by a dedicated external service, built for
cross-service consistency at massive scale.

**This engine stays in-DB / in-monolith on purpose.** Scoped-role rows are
ordinary tables in the host app's database; resolution is a local query inside a
single Rails app. That trades planet-scale distributed consistency for
simplicity, transactional integrity with the rest of your data, and zero extra
infrastructure. It is the right tool when your authorization data lives in the
same database as your domain data and you don't need a shared authorization service
across many services.

### 6.3 Against the Rails library landscape (by category)

| Category | Representative gems | What that category does | Where this engine sits |
|---|---|---|---|
| **Policy / enforcement layer** | Pundit, ActionPolicy | Plain policy objects with predicate methods; the *enforcement point* (PEP). You write the logic. | This engine **composes with** one of these as its PEP — policy predicates delegate to the resolver. It does not replace them; it feeds them. |
| **Role storage (incl. resource-scoped)** | rolify | Stores roles, supports roles scoped to a resource. | Overlaps with the *storage* of org-wide + scoped roles, but rolify is storage only — no auto-derived permission grid, no resolver decision order, no SoD, no UI. |
| **Ability DSL** | CanCanCan | A Ruby DSL (`can :read, Report`) defining abilities in code. | This engine puts the ability set in **data + a UI grid**, not a code DSL. Abilities become editable rows, not `ability.rb`. |
| **External PDP** | Cerbos, OpenFGA | Decoupled decision service, often with its own policy language / API. | This engine keeps the PDP **in-process and in-DB** (§6.2). No external service dependency. |

### 6.4 "Is this a known named pattern?"

**No single label covers it — it is a composition.** The closest labels are:
**data-driven RBAC** (core), with **ReBAC** (scoped roles), **action-level
permissions** (the `controller#action` grain), a hard **SoD veto**, and
**Devise-style engine delivery**. What is genuinely distinctive is that *no one
Rails gem does all of these together*, and that permissions are **auto-derived
from the router** so the permission catalog maintains itself.

---

## 7. The engine / gem shape (Devise-style)

What the gem provides:

**Models** (generated into the host app, agnostic names):
- `Grantwork::Role` — `name` (unique), `full_access:boolean`, and its permission set.
- `Grantwork::Permission` — one per `controller#action` (derived; may be materialized
  or computed — see §9 caching).
- `Grantwork::RoleAssignment` — join of subject → its one org-wide role.
- `Grantwork::ScopedRoleAssignment` — join of subject → role → polymorphic resource.

**The resolver** — `Grantwork::Resolver` (the PDP), the single entry point for every
allow/deny decision, implementing the §3.7 order.

**Policy / controller integration** (the PEP):
- Integration with a host policy layer (ActionPolicy or Pundit) where predicates
  delegate to the resolver.
- A generic controller concern that maps the current `controller#action` to the
  matching permission and calls the resolver automatically:

```ruby
module Grantwork
  module Guard
    extend ActiveSupport::Concern
    included { before_action :grantwork_check! }

    private

    def grantwork_check!
      permission = "#{controller_path}##{action_name}"
      record     = respond_to?(:grantwork_record, true) ? grantwork_record : nil
      head :forbidden unless Grantwork.resolver.allow?(
        subject: current_user, permission:, record:
      )
    end
  end
end
```

**Generators** (Devise-style):
- `grantwork:install` — config initializer, migrations, model stubs, routes mount.
- `grantwork:views` (or bundled) — scaffolds the management UI (§8-adjacent, see
  below).
- Seeds — a starter set of roles (e.g. `Owner` with `full_access`, a baseline
  `Member`).

**Config points** (initializer): which subject class is the actor; the
include/exclude list for auto-derived permissions (namespaces, mounted engines,
infra actions); the host-declared "who initiated this record?" hook for SoD (§9);
the policy layer to integrate with.

**Host-app integration steps:**
1. Add gem, `rails g grantwork:install`, migrate.
2. Mount the engine (for the management UI).
3. Include `Grantwork::Guard` in `ApplicationController` (or per-controller).
4. Seed/define roles; set one org-wide role per subject.
5. Declare the SoD "initiator" hook for record types that need it.

**Scaffolded management UI (the PAP), generated:**
- **Roles index** — list of roles.
- **Role editor** — the auto-derived controller × action **permission grid**;
  tick individual cells or whole rows; a **`full_access` toggle**.
- **Scoped-role assignment** — reachable from BOTH the resource's page ("add
  someone as Editor of this record") and the subject's page ("give this user a
  scoped role on some record").
- **Subject page** — shows the single org-wide **role chip** + the **scoped-role
  chips** ("Editor of Project X", "Reviewer of Report #42").

---

## 8. Data model (agnostic ER sketch)

```
+------------------+          +---------------------------+
|   subjects       |          |   grantwork_role_assignments  |
|  (host: users)   | 1      1 |---------------------------|
|------------------|----------| subject_id  (FK)          |
| id               |          | role_id     (FK)          |   one org-wide
| ...              |          +---------------------------+   role per subject
+------------------+                        |
        |                                   |
        | 1                                 | *
        |                                   v
        | *                       +--------------------+
+---------------------------+     |   grantwork_roles      |
| grantwork_scoped_role_assigns |*   1|--------------------|
|---------------------------|-----| id                 |
| subject_id      (FK)      |     | name  (unique)     |
| role_id         (FK)      |     | full_access (bool) |
| resource_type  (poly)     |     +--------------------+
| resource_id    (poly)     |               | 1
+---------------------------+               |
        ^  scoped role targets              | *
        |  ONE specific record    +----------------------------+
        |                         | grantwork_role_permissions     |
   (polymorphic to any            |----------------------------|
    host domain record:           | role_id       (FK)         |
    projects, reports, ...)       | permission_key (str)       |  "reports#approve"
                                  +----------------------------+
                                              ^
                                              | permission_key mirrors
                                              | one controller#action,
                                              | auto-derived from the router
                                  +----------------------------+
                                  | grantwork_permissions (opt.)   |  materialized OR
                                  |----------------------------|  computed at runtime
                                  | key  "controller#action"   |  (see §9 caching)
                                  +----------------------------+

SoD: enforced in code (the resolver's step 1), keyed off a host-declared
     "who initiated this record?" hook. NOT a table row, NOT editable.
```

---

## 9. Open questions / iteration points

*Listed, not resolved.*

1. **Single vs multi org-wide role.** This concept picks **exactly one** org-wide
   role per subject (simpler mental model, simpler resolution). Alternative:
   allow multiple org-wide roles unioned together — more flexible, but
   reintroduces "which role granted this?" ambiguity and complicates the subject
   page. Decision pending.
2. **Do scoped roles carry their own bundle, or fixed capabilities?** Current
   description: a scoped role reuses a full `Role` (its whole permission bundle,
   applied on one record). Alternative: scoped roles expose a *restricted* or
   *fixed* capability set distinct from org-wide roles. Undecided.
3. **Resource hierarchy / cascade (§4).** Should a scoped role on a parent apply
   to children? If so: declared traversal, depth limits, cycle handling,
   performance. Not designed.
4. **Performance + caching.** (a) Auto-deriving the controller × action grid on
   every render vs materializing `grantwork_permissions`. (b) Per-request resolution
   cost — caching a subject's effective permission set, and invalidating it when
   roles are edited in the UI. Strategy undecided.
5. **Auto-derivation edge cases.** How namespaces (`admin/reports#index`),
   mounted engines, and non-RESTful/infra actions (webhooks, health checks,
   callbacks) enter or are excluded from the grid. Needs a declared
   include/exclude policy.
6. **UI stack for the scaffolds.** ERB (Devise-like, host-agnostic) vs Hotwire
   (nicer grid interactions, more assumptions) vs a host-agnostic component
   approach. Trade-off between zero-assumption portability and UX.
7. **How SoD identifies "the requester" generically.** The engine can't know
   which column/association means "who initiated this record" across arbitrary
   host models. Needs a **host-declared hook** (e.g. `grantwork_initiator` on the
   record) — shape and default behavior undecided.
8. **Audit / versioning of role edits.** Roles are edited live in the UI. Should
   every edit be versioned/audited (who changed what, when, rollback)? Likely
   yes for a security control, but not specified.
9. **Testing story.** How host apps test their authorization (resolver unit
   tests, policy tests, request specs asserting `403`s), and what test helpers
   the gem ships. Undefined.

---

## Additional Ideas & Concepts

*Capture-only. Ideas to explore, not designs to build. Nothing here is decided.*

### A. Feature flags as a complementary layer

Idea: pair the permission system with **feature flags** for a second, orthogonal
axis of control. A flag answers *"is this capability even live for this actor?"*
— independently of *who is permitted* to use it. The two compose cleanly because
they answer different questions and run at different stages:

```
1. feature flag  → is this feature/controller live for this actor?   (if off → not even visible)
2. permission    → may this actor perform this action?               (§3.7 resolver)
3. SoD veto      → ... unless four-eyes forbids it                    (§3.6)
```

The flag gate runs **BEFORE** the permission check: it can enable/disable a whole
capability or controller **globally, per-role, per-subject, or as a percentage
rollout**. Only for actors who *see* an enabled feature does the permission layer
then decide *who among them may act*. A dark-launched `orders#approve` controller
could be flag-gated to 10% of subjects; within that 10%, roles still decide who
may approve, and SoD still vetoes self-approval.

Implementation could **wrap an existing feature-flag gem** or be a **light
built-in** — undecided.

Open sub-questions (do not resolve):
- **Flag scope granularity** — per-feature, per-controller, per-action? How does
  flag scope line up with the permission grain?
- **Precedence vs permissions** — always flag-first? Can a permission ever
  override a flag, or is the flag strictly an upstream gate?

### B. Ambient / portable `current_user` — invisible authorization in controllers, views, and ViewComponents

Idea: make the **authorization context** (the subject = `current_user` + the
resolver) available **portably and invisibly everywhere** — not only at the
controller-action gate, but inside views and especially **ViewComponents** —
without manually threading `current_user` through every call. A component could
ask:

```ruby
allowed_to?(:approve, report)   # or can?(:approve, report)
```

to conditionally render — e.g. hide an "Approve" button the subject can't use —
using the **same decision engine** as the controller gate. One source of truth
from the controller down to the smallest component; the view can never disagree
with the enforcement layer because they call the same resolver.

**Attribution:** this ambient-authorization-context pattern has been popularized
by **Evil Martians**; the exact author/source is **TBD** (not invented here).
Likely mechanisms to evaluate:
1. **ActionPolicy's "implicit authorization context"** — e.g.
   `authorize :user, through: :current_user` — which already flows the subject
   everywhere and ships a ViewComponent integration.
2. **A dry-rb approach** — `dry-effects` "Reader" effect to provide an ambient
   `current_user` without globals.
3. **Rails' native `CurrentAttributes`** — request-scoped ambient state.

Framing: the engine should expose a **portable authorization-context mixin** so the
resolver works identically in controllers, views, and ViewComponents.

Open sub-questions (do not resolve):
- **Which mechanism** (ActionPolicy implicit context vs dry-effects Reader vs
  `CurrentAttributes`), or a blend?
- **Ambient-context vs explicit-pass trade-offs** — invisibility/ergonomics
  versus the "magic global" smell and traceability.
- **Testability** — how to set/reset the ambient subject in unit and component
  tests without leakage between examples.
- **Thread / fiber safety** — correctness under threaded servers and fibers
  (`CurrentAttributes` resets per request; other mechanisms differ).

---

## 10. Non-goals

- **Authentication.** Login, sessions, passwords, magic links — not this engine's
  concern. Pair with Devise (or similar) for AuthN.
- **Being an external PDP.** No dependency on Cerbos/OpenFGA or any external
  decision service; the PDP is in-process and in-DB by design.
- **Multi-tenancy specifics.** Beyond noting that org-wide roles are
  "organization-wide", this engine does not prescribe a tenancy model. Trivially
  compatible with a host's tenant scoping, but not solved here.
- **UI theming / design system.** Scaffolds are functional, meant to be
  overridden/restyled by the host — like Devise views. Not a design system.
```
