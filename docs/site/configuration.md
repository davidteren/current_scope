---
title: Configuration
nav_order: 6
---

# Configuration reference

Everything lives in `config/initializers/current_scope.rb`, created by the
install generator. The
[generated initializer](https://github.com/davidteren/current_scope/blob/main/lib/generators/current_scope/install/templates/initializer.rb)
and
[`Configuration`](https://github.com/davidteren/current_scope/blob/main/lib/current_scope/configuration.rb)
are canonical — each knob's full contract is documented there, in the source
a mismatch cannot hide from. This page is the map.

## Identity

| Knob | Default | What it does |
|---|---|---|
| `user_method` | `:current_user` | Host method that returns the effective subject. A controller that doesn't respond to it raises (never a silent 403-everything). |
| `actor_method` | `nil` | Host method returning the **real** actor behind an impersonated session. **Security-critical the moment you impersonate** — unset, the mutation guard and SoD `:either` are inert and audit rows attribute to the impersonated subject. `record_impersonation_started!` raises if it's unset. |
| `subject_class` | `"User"` | The model that holds roles. |
| `subject_label` | `nil` | How the management UI names a subject: a Symbol (method), a Proc, or nil for best-effort (email → name → first+last → label). A label that raises degrades to the default chain and logs — it never breaks the page. |

## Enforcement

| Knob | Default | What it does |
|---|---|---|
| `enforcement` | `:enforce` | `:enforce` = a denial is a 403, the only production posture. `:report` = log missing grants and let requests through (`access.would_deny` ledger rows; the adoption ramp). Relaxes *only* "no grant" — SoD, the console, and the impersonation gate still refuse. Unknown value raises at boot. |
| `collection_read_actions` | `["index"]` | Record-less actions whose gate derives its answer from the scoped list (`scope_for`), so gate and list cannot disagree. Read-only names only — a full key raises; a mutating name warns loudly. |
| `excluded_controllers` | rails/active_storage/action_mailbox/turbo/current_scope internals | Regexps excluded from the permission grid. Excluded controllers can't be granted, so they must also skip the gate — and are then **unprotected by CurrentScope** ([checklist § 1](security-checklist.md)). |
| `parent_controller` | `"::ApplicationController"` | What the management UI inherits from (host auth and before_actions). |

## Separation of duties

Covered in depth in the [SoD guide](separation-of-duties.md).

| Knob | Default | What it does |
|---|---|---|
| `sod_actions` | `[]` | The opt-in switch. Empty = the veto never runs. Action names only (matched on the action segment); full keys raise. |
| `sod_identity` | `:either` | Which identities the veto weighs: `:either` = subject *and* real actor (impersonation can't launder an approval), `:subject` = effective subject only. |
| `allow_sod_bypass` | `false` | Break-glass. Off = the veto is absolute. On = liftable per record via three live-checked conditions, always audited (`sod.bypassed`). |
| `sod_bypass_permission` | `"bypass_sod"` | The grantable break-glass permission. Must not appear in `sod_actions` — the engine raises at boot if it does. |

## Impersonation

| Knob | Default | What it does |
|---|---|---|
| `allow_mutations_while_impersonating` | `false` | Impersonated sessions are read-only: non-GET/HEAD denied while actor ≠ subject. Setting `true` **raises at boot in production** unless `CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS` is set. |

## Audit

| Knob | Default | What it does |
|---|---|---|
| `audit` | `true` | Tri-state `false` \| `true` \| `:strict`. `true` records authorization changes (management UI, impersonation boundary, `grant!`) and degrades warn-once if the events table is missing; `:strict` raises instead, rolling the mutation back — the audit-mandatory posture. |

## Diagnostics (log-only, dev/test on by default)

All four default on in development and test, off in production, and never
change a decision, header, or audit row:

| Knob | Fires when |
|---|---|
| `warn_on_nil_sod_record` | An SoD action was allowed while the gate had no record — the veto was skipped. |
| `warn_on_inert_scoped_grant` | Denied `no_grant` while the subject holds a scoped grant that would satisfy it, but the controller declares no `current_scope_record`. |
| `warn_on_cross_controller_derivation` | Short-form `allowed_to?` derived a different key than this controller's gate enforces. |
| `warn_on_undeclared_collection_model` | A request was denied `model_undeclared` — a record-less action whose controller names no `current_scope_model` while the subject holds a scoped grant ticking the key; the fix is one line in the controller. The same knob gates the `model_invalid` nudge. |

| Knob | Default | What it does |
|---|---|---|
| `gating_tripwire` | `:raise` in dev/test, `:warn` elsewhere | How the opt-in `GatingTripwire` mixin speaks when an action ran without the gate: `:raise` makes CI go red; `:warn` logs each ungated `controller#action` once. No `:off` — not including the mixin is off. |

## Management UI

| Knob | Default | What it does |
|---|---|---|
| `permission_grid_groups` | read/create/update/destroy CRUD groups | How grid columns group actions per controller row. |
