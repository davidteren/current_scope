---
title: Limitations
nav_order: 9
---

# Limitations

What CurrentScope **is** and **is not**, in one place. Solid means honest
limits a host can read in one sitting.

## SSR-first today

CurrentScope is built for **server-rendered Rails** (controllers, ERB/Haml,
ViewComponents, Turbo). The ambient context and `allowed_to?` / `scope_for`
work anywhere the request has already established the subject.

**Not first-class yet:**

| Surface | Status |
|---|---|
| Separate JS front-end (React/Next over an API) | Open — [#96](https://github.com/davidteren/current_scope/issues/96) |
| Inertia.js shared props + denials | Open — [#97](https://github.com/davidteren/current_scope/issues/97) |

You can still authorize API requests that hit Rails controllers with Guard.
There is no shipped abilities payload, client SDK, or Inertia shared-props
contract. Do not plan a SPA cutover expecting that to exist today.

## Intentional residuals (do not "fix open")

These are deliberate product choices, not forgotten bugs. Documented so
operators and auditors know what to expect.

### A17 — Report mode does not absorb a missing `current_scope_initiator` (#133)

An action listed in `config.sod_actions` that reaches a model defining no
`current_scope_initiator` raises `CurrentScope::ConfigurationError`, and the
request returns **500 — under `config.enforcement = :report` exactly as under
`:enforce`**. Report mode downgrades a missing grant; it does not downgrade a
misconfiguration. Letting the request through would run a separation-of-duties
action with the veto never consulted, and answering 403 instead would make a
wiring mistake look like an ordinary denial.

**Host should:** audit `config.sod_actions` against your models before turning
report mode on. Since #133 the engine helps: it logs a **preflight warning at
boot** naming every SoD action whose declared model cannot answer the hook, and
`bin/rails current_scope:report` lists both that static set and the requests that
actually raised (`access.sod_initiator_missing` rows).

**Operators should know:** the boot list is **partial by construction**, for the
same reason A16 is advisory. It can only inspect controllers that declare
`current_scope_model`, so an action without that declaration is *absent* from the
list rather than cleared; and the declared type names what the collection lists,
so a member action loading a different type is named against the wrong model. The
ledger rows are the proof the boot list cannot be.

### A16 — "check hooks" is advisory, not a verdict (#134)

The engine cannot prove which records a controller resolves to:
`current_scope_record` and `current_scope_model` run at request time. The
**check hooks** signal therefore compares the grant's type against the route
keys its role ticks, and inherits that comparison's blind spot for a controller
serving a type under a different name.

**Host should:** read the record hook before removing a grant on this signal
alone. The separate **cannot match** signal *is* proven and holds whatever your
hooks do.

### A15 — A declared chain is bounded at five hops, and truncation is silent to the user (#108)

`CurrentScope::ParentChain::MAX_PARENT_DEPTH` is 5. A grant held more than five
hops above a record does not match it, and a loop in the data
(`parent_id` pointing back up the tree) stops the walk where it repeats.

Both cases **deny** — fewer ancestors can only mean fewer grants match, never
more — and both log a warning naming the class and the reason. Neither raises.
That is deliberate: the chain shape is often *data*, so raising would let two
`UPDATE`s on a foreign key turn a live request into a 500 and break report
mode's promise never to break a request.

**Host should:** keep hierarchies within five levels, and add an acyclicity
check on write if users can re-parent records. Watch the log for
"current_scope_parent stopped walking" if a subject is missing access they
should have.

**Also true:** a parent-scoped grant opens member actions and collection
**reads**, but never a record-less non-read action such as `#create`. A role
that ticks `reports#create` and is held on a Project opens the index and 403s
`new`/`create`. Grant record-less keys org-wide, or on the collection's own
type.

### A14 — A scoped `full_access` grant does not cascade to children (#108)

When a model declares `current_scope_parent`, only roles that **explicitly tick
the key** reach its children. A scoped `full_access` grant reaches the record it
was granted on and stops there.

This is deliberate. Cascading it would mean one scoped `full_access` grant on a
root record opened every permission on every descendant, which is a far larger
grant than ticking one box implies. The visible oddity is that privilege stops
being monotonic in this one place: a `full_access` role reaches **fewer** records
through a chain than a role that merely ticks the key.

**Host should:** tick the keys on the role when blanket authority over a subtree
is what you want. The role editor's full-access label states the carve-out.

**Operators should know:** since **#134** the console and
`bin/rails current_scope:report` flag a scoped grant whose role can never match
anything, and separately flag one whose ticked keys do not name a controller for
the grant's type. The second is an **advisory, not a verdict** — see A16.

### A5 — Org grant + nil SoD record skips the veto

On an SoD-listed **member** action, if `current_scope_record` returns `nil`
(or a non-record), the veto has no initiator to measure and is **skipped**.
An org-wide grant can then allow the initiator through.

**Host should:** always return the AR record on SoD member actions. Dev/test
nudges (`warn_on_nil_sod_record`) and report-mode `access.sod_blind_spot`
surface the mistake. See the
[SoD guide](separation-of-duties.md).

Returning the record is only half of it — the model it belongs to must define
`current_scope_initiator`, or the gate raises instead of skipping. See A17.

### A2 — `actor_method` is only loud at boundary APIs

Without `config.actor_method`, the engine cannot see impersonation. SoD
`sod_identity = :either` and the mutation guard need it. We do not auto-detect
Pretender (or similar) wiring — false auto-detect would be worse than silence.

**Host should:** set `actor_method` when you impersonate; include the
[security checklist](security-checklist.md) item. Doctor/DX skill (#46) may
nudge later.

### A6 — `audit = true` degrades without the events table

If the ledger table is missing, `audit: true` **warns once and continues** so
upgrades do not hard-crash. Commits that would have been audited are not.

**Host should:** use `config.audit = :strict` when the ledger is mandatory
(production fraud-control). Run migrations before enabling.

### Trusted `current_scope_model`

The declared collection type is trusted like `current_scope_record`. A wrong
type + scoped full_access can open that controller's listed reads for the
wrong resource family (the #65 trade).

**Host should:** review the model hook the way you review the record hook.

### Report mode hard-403s `:model_undeclared` / `:model_invalid`

Report mode relaxes **only** ordinary `:no_grant`. The labels
`:model_undeclared` / `:model_invalid` appear when a **scoped grant would
otherwise satisfy** the record-less permission but the model hook is missing
or unusable — those stay hard 403 (with a reason header and a dev nudge).
With no qualifying scoped grant, the denial is plain `:no_grant` and report
mode still observes it. Deliberate: a retrofit must not wave through "you
forgot the type hook" when a grant is present.

**Host should:** declare `current_scope_model` (and a valid AR class) on
collection controllers that need scoped grants.

### GatingTripwire is opt-in

Controllers that never include `Guard` are not auto-gated. Auto-including on
every Metal controller would surprise hosts.

**Host should:** include Guard on app bases you care about, and optionally
`GatingTripwire` / `bin/rails current_scope:ungated` for inventory. Recommended
on the [security checklist](security-checklist.md).

### Parent/child cascade is opt-in, one declaration at a time

A scoped grant on a Project does **not** open Tasks under it *unless* Task
declares `current_scope_parent` (#108). Flat is the default and stays the
default; see A14 and A15 above for the two limits that come with opting in.

## Related

- [Security checklist](security-checklist.md) — deploy footguns
- [Upgrading](upgrading.md) — silent posture flips between versions
- [Solid-solution worklist Track 8](https://github.com/davidteren/current_scope/blob/main/docs/reviews/grok-whole-app-2026-07-19/08-solid-solution-worklist.md)
  — source residuals table
