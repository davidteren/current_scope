# Concepts and glossary

> Deeper narrative definitions also live in root
> [`CONCEPTS.md`](../../CONCEPTS.md) (relationships, grant model, machinery).
> This page is the short front door for adopters and agents.

## Decision order

Every allow/deny question routes through one pure resolver, in this fixed order:

```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever     ALLOW
3. org-wide role   → role's permission set includes it   ALLOW
4. scoped role     → a role held on THIS record, or on   ALLOW
                     a declared parent (opt-in)
5. record-less     → no record: a scoped grant of the     ALLOW
                     named type opens a listed
                     collection read (index by default)
6. otherwise       → default deny
```

Step 4 also matches a grant on a declared parent when the child opted in
with `current_scope_parent`. Step 5 is why a scoped-only subject can reach
an index. A collection action names the type with `current_scope_model`.
The class form `allowed_to?(:index, Report)` names the type itself.
Without a type the grant is type-unbound and the gate stays closed
(reason `:model_undeclared`). The listed read still opens only when the
subject's scoped list is not empty, including rows reached through a
declared parent. Other record-less keys (for example `create`) need an
explicit tick on the named type; a scoped `full_access` grant does not
open those.

No grant means denied. The gate enforces that answer before the action runs.
The scoped list narrows which records the action sees. For listed collection
reads (`index` by default) the gate derives admission from the list so gate and
list agree by construction.

## Glossary

**Subject**
The identity permissions resolve against. Usually a person. Distinct from the
actor when someone is impersonating.

**Actor**
The real account behind the request. Equals the subject unless impersonating.
Attribution and the audit trail follow the actor; permission checks follow the
subject.

**Effective subject**
The subject the request acts as (impersonated user when act-as is live). Same
as `current_scope_user` / the ambient subject.

**Org-wide role**
The single application-wide role a subject may hold. Its permissions apply to
every record of every type. At most one per subject (DB-enforced).

**Scoped role**
The same role concept attached to one record ("Editor of Project #7"). Grants
nothing on other records. A subject may hold many, on different records.

**`full_access`**
A role property that satisfies every permission without listing them. Org-wide
it means everything; scoped it means everything on that record (plus listed
collection reads of that type). Step 2 of the decision order.

**Permission key**
A `controller#action` pair. The route pair *is* the permission. The catalog of
grantable keys is derived from routes, not hand-maintained.

**SoD veto**
Optional four-eyes rule: the record's initiator can never perform listed
member actions on their own record. Not grantable in the UI. Overrides even
`full_access`. Which identity counts is `config.sod_identity`: the default
`:either` weighs the effective subject **and**, while impersonating, the real
actor — so an initiator cannot approve their own record by acting as someone
else. Under `:subject` only the effective subject is weighed, which reopens
that impersonation path. See
[Separation of duties](separation-of-duties-and-break-glass.md).

**Initiator**
Who raised the record (`current_scope_initiator`). The identity SoD measures
against. Declared per model by the host.

**Break-glass**
An audited, privileged waiver of the SoD veto (`allow_sod_bypass`). Not SoD
itself. Requires config, a record flag, and an initiator-held permission. See
[Break-glass](separation-of-duties-and-break-glass.md#break-glass-override-allow_sod_bypass).

**Fail-closed**
Anything not granted is denied. Misconfiguration should fail loud, not look like
success.

**Ambient context**
Subject (and actor) carried on `ActiveSupport::CurrentAttributes` so
`allowed_to?` is identical in controller, view, and ViewComponent.

**Gate**
The enforcement point (`Guard`) that refuses an action unless the resolver
allows it. Admits or refuses; does not narrow lists.

**Scoped list**
`scope_for` — the records a subject may act on. Advisory unless the host uses
it (except collection-read actions, where the gate derives from it).

**Ledger**
Append-only history of authorization *changes* (grants, roles, impersonation
boundaries, lifted vetoes). Not a log of every allow/deny decision.

## Related guides

- [Checking permissions](checking-permissions.md)
- [Separation of duties and break-glass](separation-of-duties-and-break-glass.md)
- [Impersonation](impersonation.md)
- [Configuration reference](configuration-reference.md)
- [Testing](testing.md)
- [Adopting in an existing app](adopting-in-an-existing-app.md)
