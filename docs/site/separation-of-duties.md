---
title: Separation of duties
nav_order: 4
---

# Separation of duties: the anti-fraud guarantee

**The person who initiated a record can never approve that same record.**
That is the whole rule. It is the classic four-eyes control: the employee who
files an expense claim cannot also approve the payout, the manager who drafts
a contract cannot also sign it off.

CurrentScope enforces this as a **veto at step 1 of the resolver** — before
any role or grant is even consulted:

{% include resolver-order.md %}

Because the veto outranks everything, **a `full_access` admin still cannot
self-approve**. No role, no grant, and no tick in the management UI can lift
it. It is not editable in the permission grid. That is deliberate: a fraud
control that a sufficiently privileged person can switch off for themselves
is not a control. It is a structural guarantee, not a preference. (The one
deliberate exception is [break-glass](#break-glass-the-audited-override),
below — off by default, and a deploy-time decision, never a UI toggle.)

## It is OFF by default — you must opt in

This is the single most important fact on this page:

> **`config.sod_actions` defaults to `[]`. Empty means the veto never runs.**
> If you have not listed actions, you do not have separation of duties —
> no matter what else you configured.

The engine's baseline is scoped RBAC; many apps want nothing to do with
four-eyes, so it is opt-in by design. (It has been opt-in since v0.2 — v0.1
shipped it on by default, so if you upgraded from 0.1 without setting
`sod_actions`, your veto silently turned off. See
[Upgrading](upgrading.md).)

## Turning it on

Three declarations. First, list the actions an initiator may never perform
on their own record:

```ruby
# config/initializers/current_scope.rb
config.sod_actions = %w[approve]   # matched on the ACTION segment of the key
```

Second, tell the engine who initiated each record, on the model:

```ruby
class Report < ApplicationRecord
  def current_scope_initiator = requested_by
end
```

Third — and this one is load-bearing — the controller's
`current_scope_record` hook **must return the record on the SoD member
action** (the veto is skipped when the gate has no record; see the asymmetry
below):

```ruby
class ReportsController < ApplicationController
  private

  def set_report = @report ||= Report.find(params.expect(:id))
  def current_scope_record = (set_report if request.path_parameters[:id])
end
```

From here, when *any* subject whose identity matches the record's
initiator hits `reports#approve`, the resolver answers **deny** with reason
`sod_veto` — a 403 carrying `X-Current-Scope-Reason: sod_veto`.

### It fails loud, not open

If an action listed in `sod_actions` reaches a record whose class does not
define `current_scope_initiator`, the resolver raises a `ConfigurationError`
instead of silently permitting. Return `nil` from the hook to deliberately
exempt a record type, or trim `sod_actions`. With `sod_actions` empty this
error can never fire — no model needs the hook until you opt in.

### The one asymmetry you must know

**An SoD-gated member action must return its record from
`current_scope_record`.** A *present* record with a *missing* initiator hook
raises (above) — but if `current_scope_record` returns `nil` on an SoD member
action, the veto is **skipped**, and an org-wide-granted subject (including
the initiator) passes. `nil` is legitimate for collection actions, so the
resolver cannot tell the two apart and will not raise. Returning the record
on member actions is the load-bearing control.

In development and test the engine logs a nudge whenever an allowed SoD
action was gated with no record (`config.warn_on_nil_sod_record`, on by
default there). In report mode, a refusal the veto could not examine is
logged and recorded as a distinct `access.sod_blind_spot` ledger event, and
`bin/rails current_scope:report` lists these separately — granting a role
will not clear that 403.

## How to verify it is live

Do not trust configuration reading; test the behavior:

```ruby
test "initiator cannot approve their own report" do
  report = reports(:pending)                       # initiated by users(:ada)
  grant_role!(users(:ada), role: roles(:approver)) # a role that ticks approve

  sign_in users(:ada)
  post approve_report_path(report)
  assert_response :forbidden
  assert_equal "sod_veto", response.headers["X-Current-Scope-Reason"]
end
```

If that test passes, the veto is running. If the response is 200, or the
reason is `no_grant` instead of `sod_veto`, SoD is not examining this action
— check `sod_actions` and the two hooks above.

## Impersonation cannot launder an approval

By default (`config.sod_identity = :either`) the veto weighs **two**
identities: the effective subject *and* the real actor behind an impersonated
session. An admin who initiated a report cannot slip past the veto by
approving it while impersonating someone else. Set `:subject` to weigh only
the effective subject; the two are identical when nobody is impersonating.
This requires `config.actor_method` to be set — without it, the engine cannot
see impersonation at all (see the
[security checklist](security-checklist.md)).

## Break-glass: the audited override

Sometimes a workflow genuinely needs a *conditional* self-approval — the
trusted owner may approve their own request. `config.allow_sod_bypass = true`
promotes that pattern into the engine so the one forgettable, security-critical
step — **recording the override in the audit ledger** — cannot be forgotten.

Be honest about what this is: it converts separation of duties from a
structural guarantee into an **audited policy override**. Its legitimacy
rests on three things, all enforced:

- **Off by default.** `allow_sod_bypass` defaults to `false`; the veto is
  absolute until a deploy says otherwise.
- **Privilege-gated.** The veto is lifted for a record only when the flag is
  on, the record's `current_scope_sod_bypassed?` hook returns true, **and**
  the record's *initiator* holds the `bypass_sod` permission — a grantable
  grid column that appears only on controllers routing an SoD action, and
  only while the flag is on. Under impersonation the bypass checks the
  **initiator's** privilege, so impersonation cannot launder it either.
- **Always audited.** Every lifted veto records exactly one append-only
  `sod.bypassed` ledger event and sets
  `X-Current-Scope-Reason: sod_bypassed` on the response.

`bypass_sod` must not appear in `sod_actions`; the engine raises at boot if
it does. Prefer true SoD for genuine fraud control (contracts, pay runs)
where no override should exist — reach for break-glass only when a
conditional, privileged, audited self-approval is the real requirement.

## See it running

- The **[showcase app](https://github.com/davidteren/current_scope_showcase)**
  dramatizes the veto end to end: a multi-domain anti-fraud gallery
  (payroll / contracts / expenses), one-click act-as, and a guided
  "try to commit fraud → refused" walkthrough.
- The **[04_sod_matrix scenario app](https://github.com/davidteren/current_scope_test_scenarios)**
  is the adversarial test host that exercises every SoD knob: veto vs
  `full_access`, missing and nil hooks, the break-glass matrix, and
  impersonation × `sod_identity`.

## Full reference

The [README's SoD section](https://github.com/davidteren/current_scope/blob/main/README.md#separation-of-duties-opt-in)
is the canonical deep treatment — record-less refusals, the report-mode
blind spot, `sod_identity` modes, and the break-glass host recipe.
