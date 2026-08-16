# Separation of duties and break-glass

> See also: [Concepts & glossary](concepts-and-glossary.md).

## Separation of duties (opt-in)

Separation of duties is **off by default** — the engine's baseline is scoped
RBAC, and many apps want nothing to do with four-eyes. Turn it on by listing the
actions an initiator can never perform on their own record, and declare who
initiated each record:

```ruby
# config/initializers/current_scope.rb
config.sod_actions = %w[approve]   # empty by default → no SoD
```

```ruby
class Report < ApplicationRecord
  def current_scope_initiator = requested_by
end
```

Once enabled, the veto fails **loud, not open**: if an SoD action reaches a
record whose class doesn't define the hook, the resolver raises a
`ConfigurationError` instead of silently permitting. Return `nil` from the hook
to exempt a record type, or trim `config.sod_actions`.

That raise is a **500**, and `config.enforcement = :report` does not soften it —
report mode downgrades a missing grant, never a misconfiguration. So audit
`config.sod_actions` against your models before you enable it. The engine helps:
it logs a preflight warning **when the route set loads** (boot in production and
staging; the first request in development) naming every routed SoD action whose
controller declares a `current_scope_model` that cannot answer the hook, records
an `access.sod_initiator_missing` ledger row when a request does raise in report
mode, and lists both in `bin/rails current_scope:report`. The boot list is a
lead, not a verdict — it only sees controllers that declare
`current_scope_model`, and it states that limit in its own output.

> **An SoD-gated member action MUST return its record from `current_scope_record`.**
> This is the one asymmetry to know: a *present* record with a *missing*
> initiator hook raises (above), but if `current_scope_record` returns **nil**
> on an SoD member action, the veto is *skipped* — an org-wide-granted subject
> (including the initiator) passes. `nil` is legitimate for collection actions,
> so the resolver can't tell the two apart and won't raise. Returning the record
> on member actions is therefore the load-bearing control. **In development and
> test the gate logs a nudge** whenever an allowed SoD action was gated with no
> record (`config.warn_on_nil_sod_record`, on by default there, off in
> production) — see [Dev diagnostics](configuration-reference.md#dev-diagnostics).

With `sod_actions` empty (the default), the veto step is a no-op and the
resolver is simply `full_access → org-wide role → scoped role → record-less (listed reads via scope_for; other keys need an explicit tick) → deny`. No model
needs `current_scope_initiator` — the `ConfigurationError` above only fires for
actions that are *in* `sod_actions`. `sod_identity` is moot; roles, scoped
roles, `scope_for`, audit, and impersonation are unaffected.

> **Collection actions in `sod_actions` are no-ops.** The veto needs a record.
> Listing `approve_all` (or any collection action) does not enforce four-eyes
> on bulk work — the initiator can bulk-self-approve. Filter each row with
> `allowed_to?(:approve, record)` inside the bulk action. (#29)
>
> **Break-glass + `full_access`.** When `allow_sod_bypass` is on, a full_access
> role holds the bypass permission automatically. Prefer a narrow bypass role.
> See [UPGRADING.md](../../UPGRADING.md) for the 0.1→0.2 SoD default flip.

By default (`config.sod_identity = :either`) the veto weighs **two**
identities: the effective subject *and* the real actor behind an impersonated
session. So an admin who initiated a report can't slip past the veto by
approving it while impersonating someone else — impersonation can never approve
your own record. Set `:subject` to weigh only the effective subject. The two
are identical when nobody is impersonating (`actor == subject`), so v0.1 hosts
see no change.

## Break-glass override (`allow_sod_bypass`)

Sometimes a workflow needs a *conditional* self-approval — e.g. the owner or a
trusted admin may approve their own request. You can express that in your app
(a second `approve_own` permission plus a controller branch), but that pattern
has one forgettable, security-critical step: **recording the override in the
audit ledger**. Break-glass promotes the pattern into the engine so the audit
**cannot** be forgotten.

Be honest about what this is: it converts separation of duties from a
*structural guarantee* into an **audited policy override**. It's called
break-glass, not SoD. Its legitimacy rests on three things, all enforced: it is
**off by default**, **privilege-gated**, and **always audited**.

```ruby
config.allow_sod_bypass     = true          # default false → the veto is absolute
config.sod_bypass_permission = "bypass_sod" # grantable, editable in the role grid
```

With it on, the veto is lifted for a record **only when all three hold**,
re-checked live at decision time:

1. `config.allow_sod_bypass` is on, **and**
2. the record's host hook `current_scope_sod_bypassed?` returns true, **and**
3. the record's **initiator** holds the bypass permission (`bypass_sod`).

**Where the cell is.** Break-glass is the one permission that isn't an action
you can route, so the role grid gets it injected rather than derived: with
`allow_sod_bypass` on, every controller that routes an action listed in
`sod_actions` grows a `bypass_sod` column, blank elsewhere. Tick it on the row
for that resource and the role can break the glass — the supported way to build
a "trusted admin may self-approve" role **without** `full_access`, which would
grant it implicitly along with everything else and defeat the point of a scoped
trusted approver. Turn `allow_sod_bypass` off and the column disappears and the
key stops being grantable: grantability follows the catalog, and the catalog
follows the flag.

Holding `bypass_sod` on a flagged, self-initiated record **is** the
authorization for the SoD action — the bypass grants the action, it doesn't
merely lift the veto and then re-check for a separate `approve` grant.
`bypass_sod` must **not** appear in `sod_actions` (it isn't an SoD action); the
engine raises **at boot** if it does (and again at decision time as defense in
depth), so a re-entrant pairing fails the deploy instead of 500ing on the first
real break-glass attempt.

When a bypass lifts the veto, the engine records exactly one append-only
`sod.bypassed` audit event at the enforcement gate (never on advisory
`allowed_to?` checks) and sets `X-Current-Scope-Reason: sod_bypassed` on the
response. A missing hook means "this type never breaks glass" — fail-closed, no
error. Under impersonation (`sod_identity = :either`) the bypass checks the
**initiator's** privilege, so impersonation can't launder it.

**Host recipe** (the engine ships the mechanism; these stay yours, exactly as
impersonation ships plumbing + recipe, not endpoints):

```ruby
# 1. A per-record flag column: add_column :invoices, :sod_bypass_requested, :boolean, default: false
# 2. The hook, reading that column:
class Invoice < ApplicationRecord
  def current_scope_initiator     = requested_by
  def current_scope_sod_bypassed? = sod_bypass_requested?
end
# 3. Gate WHO may set the flag on the same bypass_sod permission (a controller
#    branch or a policy) — the engine deliberately does not own that decision.
```

Prefer true SoD for genuine fraud control (contracts, pay runs) where no
override should exist. Reach for break-glass only when a *conditional,
privileged, audited* self-approval is the real requirement. Unlike
`allow_mutations_while_impersonating`, there is no production env-gate — the
feature is per-record, privilege-scoped, and audited-by-construction, so
production is its intended home.
