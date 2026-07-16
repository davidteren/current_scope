# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings; direct edits are fine. Glossary only, not a spec or catch-all.

## Relationships

A **subject** holds at most one **org-wide role** and any number of **scoped roles**. Both are optional and independent: holding no org-wide role at all is ordinary — it is the state of someone granted access to a single record and nothing else — and holding neither is simply someone with no access yet. A role is a bundle of **permissions**; which permissions may be bundled is fixed by the **permission catalog**.

The **gate** and the **scoped list** are the two halves of every per-record feature: the gate decides whether an action runs at all, the list decides which records it operates on. Both ask the **resolver**, so they read the same grants — but they bind those grants differently, and only the gate is enforced. Where they bind differently they can disagree, and one such disagreement is live: a **full access** role held on a single record opens nothing at the gate for a record-less check, while the scoped list still returns that record. Treat "the gate let them in" and "it is in their list" as separate claims.

The **resolver** decides, the **gate** enforces, and the **ledger** records — but not the same things, and this is the easiest thing here to get wrong. The ledger holds *changes to who can do what*, plus the single audited exception: grants made and withdrawn, roles edited, impersonation begun and ended, a veto lifted. It does **not** hold decisions. An ordinary refusal leaves no trace, deliberately — a fail-closed system refuses constantly, and a record of every refusal would be noise rather than history. "It was denied" and "it is in the ledger" are unrelated claims.

## The grant model

**Subject**
The identity whose permissions are being checked — typically a person, but the host names the class. Distinct from the **actor**: they are the same until someone is impersonating, and then permissions resolve against the subject while attribution follows the actor. A subject holds at most one org-wide role and any number of scoped roles; the two are independent axes, and assigning one never changes the other. Neither is required. A subject with **only** scoped roles and no org-wide role is an ordinary state, not a broken one — it is precisely what per-record access means — and a subject with nothing at all is simply one nobody has granted anything to.

**Actor**
The real identity behind a request, as opposed to the subject it is acting as. The two differ only while impersonating: an admin (actor) operating as someone else (subject). Permission decisions read the subject; attribution and the audit trail read the actor. The distinction is load-bearing for separation of duties — if the veto only ever looked at the subject, impersonating a colleague would launder a self-approval into an allowed one.

**Initiator**
The identity a record records as having raised it — the "who" that separation of duties measures against. It is declared per record type by the host, because only the host knows which of its fields means this. Declaring nothing is a misconfiguration and says so loudly; declaring it as *nobody* is how a record type exempts itself from the veto, and is a real answer rather than an absent one.

**Permission**
One action on one resource, named as a controller-and-action pair. Everything is a permission, including the baseline abilities every signed-in user has — there are no implicit powers, so an ability that isn't granted doesn't exist.

**Role**
A named, editable bundle of permissions — a row of data, not a class. The same role means the same permission set whether held org-wide or scoped to a single record; only its reach differs. Roles are edited in the management UI, so what "Reviewer" means can change without a deploy.

**Org-wide role**
The single role a subject holds across the whole application. Grants its permissions on every record of every type.

**Scoped role**
The same role concept attached to one specific record. Being "Editor of Project #7" grants nothing on Project #8. A subject may hold many, on different records.

**Full access**
A property of a role that satisfies every permission, present and future, rather than listing them. It is a wildcard, not a bundle — which makes it safe only where a grant is bound to something: held org-wide it means "everything", and held scoped it means "everything on this record". Honoring it where nothing binds it would silently widen it to the whole application.

**Grant**
A role held by a subject, either org-wide or on a record. "Granted" describes a role a subject holds — not a decision, and not membership of a scoped list.

## The machinery

**Resolver**
The single decision point every allow/deny question routes through, in a fixed order. It is a pure function of its inputs: it reads, never writes, holds no per-decision state, and never consults ambient request context on its own. Its purity is what lets a decision be trusted identically from a controller, a view, or a background job.

**Gate**
The enforcement point: a fail-closed check that runs before every action and refuses it unless the resolver allows it. The gate **admits** — it decides whether an action runs. It does not filter what that action then does, so it cannot narrow a list the action builds for itself.

**Scoped list**
The list-side companion to the gate: the set of records a subject may act on, derived from the same grants the gate reads. It **narrows**. Unlike the gate it is advisory — the host chooses to use it — so an action that ignores it and fetches everything will show everything to anyone the gate admitted.

**Permission catalog**
The set of permissions that exist and may be granted, derived from the application's routes rather than stored in a table. Referred to as "the catalog" where context makes it unambiguous. A new resource becomes grantable by existing; nothing is maintained by hand. It is the single definition of grantability: the role editor renders from it, the role form validates against it, and the gate refuses to guard anything outside it.

**Record-less target**
A permission check with no particular record to decide about — asking "may I open this list at all?" rather than "may I touch this record?". It must mean *there is no record here*, stated deliberately, and not *a record was expected and we failed to find one*: treating the second as the first turns a question about one record into a claim about all of them. The two are not distinguishable from the value alone, which is why saying which one is meant is the host's job rather than something inferred. A record-less target still carries a **type** — the controller declares it (`current_scope_model`), so a scoped grant opens the list gate only for records of that type; without a declared type the check fails closed, because a grant on one type must not open another type's list.

## The record

**Ledger**
The append-only history of *changes* to authorization — grants made and withdrawn, roles edited, impersonation begun and ended — plus the one audited exception, a lifted veto. It is not a decision log: an ordinary allow or refusal is never recorded. Rows are never rewritten: there is no notion of editing a past event, and the history outlives the things it names — a role that was deleted still renders in its own history, because each entry keeps a human label for its target rather than only a reference to it.

Append-only is a design rule enforced at the record layer, not a guarantee the storage engine makes. Bulk operations and raw queries reach past it; how much the database itself refuses depends on which database it is. Treat the ledger as tamper-*evident* by intent and honest about its ceiling, not as tamper-proof.

**Event**
One entry in the ledger: who did it, on whose behalf, to what, and what changed. Both identities are always present — they are the same entry unless someone was impersonating, so the impersonated entries are exactly the ones where they differ, which is what makes "what did this admin do while acting as someone else" answerable at all.

**Audit mode**
How a host wants the ledger treated, of which there are three postures rather than a switch: off (record nothing), on (the default), and mandatory (a change that cannot be recorded must not happen — it is rolled back rather than silently proceeding unrecorded). The third exists because for some hosts an unrecorded change is worse than a failed one.

The tolerance in "on" is narrower than it sounds, and worth knowing before relying on it: it forgives exactly one thing — the ledger never having been installed, which is what an existing host hits when it upgrades and has not yet run the migration. That case warns once and carries on. Any *other* recording failure still raises, in every mode. "On" is not a promise that recording can never break a request.

## The constraints

**Separation of duties**
The rule that whoever initiated a record can never be the one to approve it — four-eyes. It is a veto, not a grantable permission: it cannot be ticked, configured away in the UI, and it overrides every role including full access. Opt-in by listing which actions it covers; listing none makes it inert.

Because it is defined in terms of a record's initiator, it is meaningless without a record — which is why a check with no record to name is not something it can decide.

**Break-glass**
An audited, privileged override that lifts the separation-of-duties veto for a record. It converts that veto from a structural guarantee into a policy exception, so its legitimacy rests entirely on three properties, all re-checked at the moment of the decision: it is off unless enabled, it requires the record itself to opt in, and it requires the **initiator** — not whoever is asking — to hold a specific permission for it. Keying the last one on the initiator is what stops impersonation laundering the override.

A lifted veto is recorded wherever the gate enforces it and the audit ledger is switched on; a host that turns the ledger off still gets the override and keeps no trail of it. Advisory checks never record, because they never enforce.

**Fail-closed**
The posture that anything not granted is denied, and that a mistake resolves toward refusal rather than permission. Its counterpart obligation is loudness: a misconfiguration must announce itself, because a silent denial nobody can diagnose is only marginally better than a silent allow.

## The surfaces

**Console**
The management UI the engine mounts: where roles are edited, grants made, and the ledger read. It is the one place permissions are *granted*, which is why it cannot be gated by a grantable permission — that would be circular — and is instead open only to **full access** held org-wide.

**Permission grid**
How the console presents the **catalog**: one row per controller, one column per action or group of actions, a tick where the role holds it. It is an aligned matrix by design — a blank cell means the controller does not route that action at all, which is a different statement from an unticked one, and the alignment is what lets a reader scan a column down the whole application.

**Group**
A column that stands for several actions at once, so that the everyday CRUD verbs read as one decision rather than seven. A group a role holds only *part* of is the interesting case: it renders as neither on nor off, and re-saving the form must not quietly promote it to the whole group. That is a real escalation, and it is the reason the partial state exists rather than being rounded to the nearest checkbox.

**Pickable type**
A record type that has opted into being offered in the console's scoped-grant picker. Opting in is a **browsing** convenience, not a permission boundary: any record can be the target of a scoped grant whether or not its type opted in, so a type's absence from the dropdown means "not offered here", never "not grantable". Reading it as a restriction is the mistake it invites.

## The safety aids

These exist because the engine's guarantees have edges the engine cannot see past on its own. Each one is opt-in, and each one is a way of asking the host to confirm something the library would otherwise have to assume.

**Tripwire**
An opt-in check that catches an action which ran without being gated at all. The gate can only speak for controllers that installed it, so the dangerous case — a controller that never did — is invisible from inside. The tripwire is included on that controller deliberately, and complains after the fact. It cannot see an action that never reached its end, so it is a strong aid rather than total coverage.

**Test helpers**
The grant-making tools a host's own test suite uses, so that a test can put a subject in a given state without reaching into storage and without depending on the console. They exist because a fail-closed library makes every ungranted test fail, and the fix for that should be one honest line in a test rather than a workaround.

## Flagged ambiguities

- "Granted" had been used for both *holding a role* and *passing a check* — these are distinct. A subject can hold a grant and still be denied (the veto outranks it), and can be admitted by a check without appearing in any scoped list.
- "The gate lets them see it" conflates two things the codebase keeps apart: the gate admits an *action*; the scoped list determines the *records*. An action that is admitted but unscoped shows everything it fetches.
