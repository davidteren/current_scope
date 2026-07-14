# CurrentScope — Roadmap, Gaps &amp; Proposals

> Forward-looking companion to [STATUS.md](../STATUS.md) (what's *done*) and
> [README.md](../README.md) (how to *use* it). This doc holds what's **not** built
> yet, why it matters to a host app, and two concrete design proposals (demo
> redesign + scoped-assignment UX). Nothing here is committed behavior.

## 1. Coverage today (v0.1)

The core model is complete and enforced (see STATUS for the checklist): permissions
auto-derived from `controller#action`; roles as editable data; **one org-wide role
per subject** (DB-enforced) + **unlimited per-record scoped roles**; `full_access`;
the fixed resolver order (SoD → full_access → org role → scoped role → deny);
fail-closed; a **loud** SoD veto; and one ambient context so `allowed_to?` is
identical in controllers, views, and ViewComponents. Management UI + install
generator + green test suite + demo app all present.

What follows is everything the core deliberately left out.

### Design note — scoped roles are load-bearing (not optional for many hosts)

A flat role (a `controller#action` granted org-wide) is enough **only** when the rule
is *"anyone with this role may act on **any** record."* Scoped roles earn their place
the moment the rule becomes *"may act only on the records they're tied to"* — e.g. a
manager who may view/download the data for **the resources they own**, and must **not**
see anyone else's. A flat grant would leak every record; only a per-record (scoped)
grant expresses *"…but only mine."*

Distinguish this from a plain **association**: "who is the manager of X" as a label for
display, notification, or routing is just a DB column — it belongs in the authorization
engine **only when it gates access**. When it gates, it's a scoped role; when it's only
a label, it isn't. Both can coexist on the same record.

## 2. Gaps &amp; planned additions

Ordered by how often a real host app hits them. Each is additive — none changes the
v0.1 model.

> **Shipped since this section was written** (see [STATUS.md](../STATUS.md) for
> details) — the items below are kept for their rationale, but they are **built**:
> **2.1 Audit** (append-only `current_scope_events` ledger), **2.2 Impersonation /
> act-as** (`Current.actor` + `sod_identity` + read-only `MutationGuard`),
> **2.4 Resolver memoization** (per-request org-role memo on `CurrentScope::Current`),
> and **2.6 `scope_for`**. Still open: **2.3 hierarchy/cascade** and **2.5 feature
> flags**. Also shipped beyond this list: the admin dashboard UI, a role-side
> **members** view, and a **break-glass** SoD override (`allow_sod_bypass`).

### 2.1 Audit / change history &nbsp;·&nbsp; priority: HIGH
- **What:** a durable record of every authorization change — role created/renamed,
  a permission ticked/unticked on the grid, an org-wide role assigned, a scoped role
  granted/revoked — with who and when.
- **Why a host app needs it:** "who gave this person access, and when?" is a baseline
  question in any audited/regulated deployment. Today those mutations leave no trace.
- **Rough shape:** optional integration — detect and use PaperTrail if the host has
  it, else a small `current_scope_events` table; a config toggle; the actor comes
  from the ambient context (see 2.2). Never mandatory.

### 2.2 Impersonation / "act-as" awareness &nbsp;·&nbsp; priority: HIGH
- **What:** many host apps let an admin act as another user (support, debugging).
  The ambient context must distinguish the **real actor** from the **effective
  subject**, and the rest of the system must use the right one.
- **Why:** without this, an impersonated session either can't be represented at all,
  or silently attributes actions to the wrong person — which corrupts both the SoD
  veto and the audit trail.
- **Rough shape:** `CurrentScope::Current` carries both `actor` (real) and `subject`
  (effective); a config hook resolves the pair from the host's impersonation
  mechanism. Permission checks resolve against the **effective subject**; **audit
  records the real actor**; SoD gets a config choice for which identity it keys off
  (default: effective subject, with the actor recorded). Also decide whether mutating
  actions are allowed at all while impersonating (a host policy, surfaced as config).

### 2.3 Resource hierarchy / cascade &nbsp;·&nbsp; priority: MEDIUM (opt-in)
- **What:** optionally let a scoped role on a *parent* record grant on its children —
  e.g. a role on a container applying to the items inside it.
- **Why:** common when resources nest; today scoping is strictly flat ("Editor of
  Project #7 grants nothing on Project #8", and nothing cascades down).
- **Rough shape:** a host-declared `current_scope_parent` hook the resolver can walk
  up when no direct scoped grant is found. **Flat stays the default** — cascade can
  surprise, so it's opt-in per resource type. Guard against cycles + unbounded walks.

### 2.4 Resolver memoization / caching &nbsp;·&nbsp; priority: MEDIUM (perf)
- **What:** the resolver currently queries per call (`RoleAssignment.find_by` + a
  scoped-grant query on every `allowed_to?`). A page with a control per row fires N
  queries.
- **Rough shape:** request-scoped memoization in the ambient context — load the
  subject's org role, their scoped grants, and the derived catalog once per request;
  **never cross-request** (would break the "edit a role, effective next load"
  guarantee). A batch helper for "which of these records may I X?" for lists.

### 2.5 Feature flags (complementary layer) &nbsp;·&nbsp; priority: LOW (opt-in)
- **What:** gate whether a capability is even *live* for an actor (global / per-role /
  per-subject / percentage) **before** the permission check runs.
- **Layering:** flag ("is this feature on for this actor?") → permission ("may they do
  this action?") → SoD veto. Orthogonal to roles.
- **Rough shape:** optional — wrap an existing flag gem or ship a light built-in. Open
  sub-questions: flag scope granularity; precedence vs permissions. Capture-only for now.

### 2.6 Record-scope queries — "which records may I see?" (`scope_for`) &nbsp;·&nbsp; priority: HIGH
- **What:** the resolver answers *"may I act on THIS record?"* (`allowed_to?`). A
  scoped user's **list** view needs the complement — *"which records may I act on?"* A
  manager's index must show only the resources they're scoped to, not all of them.
- **Why:** today the host hand-writes that filter query, so the list and the per-record
  gate become two separate sources of truth that **drift** — a list that shows a record
  the gate would deny, or hides one it would allow. The two must derive from the same
  place.
- **Rough shape:** a companion `scope_for(Model)` helper (à la Action Policy scopes)
  that builds the visible relation from the *same* roles + permissions + scoped grants
  the resolver uses: an org-wide grant contributes "all records of this type"; scoped
  grants contribute "the specific records I'm tied to". One source of truth for both the
  gate and the list; fail-closed (no grant → empty relation).

## 3. Proposal — the demo app (standalone, hostable, multi-domain)

**Move it out of the gem.** Promote the demo to its **own standalone, deployable Rails
app in its own directory** (kept out of the gem package), so it can be **hosted live**
as the public "see what CurrentScope does" showcase. (When it moves, update the README
demo link.)

**The narrative spine: "try to game the system — you can't."** CurrentScope's SoD veto
*is* separation of duties — the classic anti-fraud control from finance and audit. The
demo should dramatize exactly that: put the visitor in the shoes of someone trying to
push their own money or contract through, and show the system refuse — structurally,
loudly, with no button and a 403 on a crafted request. That's a far more memorable
pitch than "here's a permissions grid."

**Several domains in one app — it's a gallery, not a single example.** A domain
switcher across a few small, self-contained business flows, each dramatizing SoD +
scoped roles + the auto-derived grid. There's nothing stopping multiple domains, and
the contrast is itself part of the story. Candidates (all agnostic):

1. **Payroll / salary run (recommended headline).** An operator *prepares* a pay run;
   a *different* approver must sign it off before it pays. The preparer can never
   approve their own run (SoD). Scoped: "Payroll approver for *this* department."
   Fraud beat: act as the preparer, try to approve the run you just prepared → refused;
   try to slip your own raise through → the Approve control isn't even rendered, and a
   crafted POST 403s.
2. **Contracts / procurement.** Someone raises a contract or purchase order; a
   different authority approves; large amounts need a second approver. Can't-approve-own
   = anti-collusion. Scoped: "Approver for *this* cost-centre / vendor."
3. **Expense claims.** The textbook case: submitter ≠ approver; a manager scoped to
   *their team's* claims only.
4. *(Lighter, optional)* **Editorial.** Author submits, editor approves ("not your
   own"); "Editor of *this* publication" scoped. A softer domain for contrast.

Seed each domain with a handful of users that each land on a different resolver branch
(full-access / org-role-only / scoped-only / nothing).

**Built into the demo app:**
- **Impersonation — "Act as / View as."** A switcher to *become* any seeded user and
  watch the *same* screen re-render for their permissions: buttons and sections appear
  and vanish; the Approve button disappears on your own record. The single most
  convincing proof of the ambient context (gate = view) *and* the fraud control — and
  the forcing function that proves the gem's planned impersonation support (§2.2).
- **A user-admin surface.** A users screen listing every user with their **org-wide
  role + their scoped roles** at a glance, plus the controls to assign/change them — so
  a visitor can *see who can do what*, flip a grant, and watch behavior change. Doubles
  as the showcase for the management UI (and consumes the §4 model→record picker).
- **The guided "try to commit fraud" walkthrough + a live grid.** A scripted path
  ("act as the preparer → try to approve your own run → watch it refuse"), alongside a
  live permission grid where toggling a permission changes the page on next load —
  "authorization as data," demonstrated in one sitting.

Dependency note: the demo is where impersonation (§2.2) and the audit trail (§2.1) get
proven end-to-end, so build them alongside the demo rather than after.

## 4. Proposal — scoped-role assignment UX (model → record picker)

**Problem (current):** granting a scoped role asks the operator to paste a raw
GlobalID (`gid://app/Project/7`) into a text field, unless they deep-linked from a
record's page. Error-prone and opaque.

**Proposed flow:** a guided picker —
1. choose the **Role**;
2. choose the **Subject**;
3. choose the **Resource type** from a dropdown of *scopeable* models;
4. choose the **Record** from a searchable dropdown/autocomplete of that model's
   records (labelled via the existing `current_scope_label`).

The GlobalID stays the storage form under the hood — the UI just *builds* it from
(type, record) instead of asking a human to type it. The existing "link from a
record's page" path stays and simply pre-selects type + record (the two-door pattern).

**Needs:** a **registry of scopeable resource types** so the type dropdown isn't every
model in the app. Two options to decide between:
- explicit config: `config.scopeable_resources = [Project, Report, ...]`; or
- opt-in mixin: models `include CurrentScope::Scopeable`.

**Open sub-questions:** how records are listed for large tables (search /
pagination, not "load all"); how records are labelled; explicit-config vs opt-in
mixin; whether to restrict *which roles* are grantable on *which types*.

---

*Draft — captures gaps + proposals as of the v0.1 core. Not committed scope; the
demo redesign and scoped-UX picker are proposals to iterate on.*
