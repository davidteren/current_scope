---
title: For AI agents
nav_order: 8
---

# For AI agents (and the people driving them)

Increasingly the "reader" of authorization docs is an AI coding agent. These
prompts encode the foot-guns this documentation already knows about, so an
agent gets the integration right on the first try. Copy, adjust the names,
paste.

There is also an [`llms.txt`](llms.txt) index of this site, and every page
here links to its canonical in-repo source — point your agent at those for
depth.

## Install CurrentScope in this app

```text
Add the current_scope gem to this Rails app (Rails >= 8.1, < 9 required).

1. Add `gem "current_scope"` to the Gemfile, then run:
   bin/rails generate current_scope:install
   bin/rails current_scope:install:migrations && bin/rails db:migrate
2. In ApplicationController, include CurrentScope::Context and
   CurrentScope::Guard (in that order). Authentication must be wired
   BEFORE these concerns run — Context reads current_user when its
   callback fires, so an auth callback registered after these includes
   means the gate denies before authentication happens.
3. The gate is fail-closed and covers EVERY action. You MUST add
   `skip_before_action :current_scope_check!` to controllers where
   authorization does not apply — sign-in/sessions (or nobody can log in),
   webhooks, health checks. A skipped controller is unprotected by the
   permission gate: keep or add the app's own auth there. If the app has
   act-as/impersonation, ALSO add
   `skip_before_action :current_scope_mutation_guard!` on sign-in,
   sign-out, and the stop-impersonation action — that guard is a separate
   callback that survives the gate skip, and without its skip an
   impersonating admin cannot sign out or stop impersonating.
4. If this app already has users and traffic, set
   `config.enforcement = :report` in the initializer BEFORE deploying,
   run the test suite, then run `bin/rails current_scope:report` and seed
   the roles it names. Flip back to :enforce only when re-exercising the
   app adds no NEW access.would_deny rows (the report reads the
   append-only ledger — historical rows never clear) and any
   access.sod_blind_spot rows are resolved. Report mode must not be the
   final state.
5. Bootstrap the first admin (the management UI only admits full-access
   subjects): `bin/rails current_scope:grant SUBJECT_ID=<id>` — or, in
   seeds, `CurrentScope.grant!(user)` (it creates the default
   Owner/Member roles if missing; Member starts with zero permissions).
6. Declare record hooks as PRIVATE controller methods. For member actions:
   `def current_scope_record = (set_thing if request.path_parameters[:id])`
   — key off request.path_parameters, never params, so a ?id= query string
   cannot smuggle a record into collection actions. Use the route's actual
   member key: a route declared with a custom param (e.g. :slug) must
   check request.path_parameters[:slug], or the hook returns nil and the
   SoD veto is silently skipped on that action.
7. Run the full test suite. Expect controller tests to 403 until grants are
   seeded — use the test helpers (grant_role!/grant_scoped_role!) from
   current_scope/test_helpers, not stubs.

Before finishing, read docs/SECURITY-CHECKLIST.md in the gem repo
(https://github.com/davidteren/current_scope/blob/main/docs/SECURITY-CHECKLIST.md)
and verify each item that applies.
```

## Enable separation of duties on an approve flow

```text
Enable CurrentScope separation of duties so an initiator can never approve
their own record. SoD is OFF by default — config.sod_actions = [] means the
veto never runs.

1. In config/initializers/current_scope.rb set
   `config.sod_actions = %w[approve]` (action NAMES, not full keys).
2. On the model, define `def current_scope_initiator = <initiator assoc>`.
   If an SoD action reaches a record whose class lacks this hook, the
   resolver raises ConfigurationError — that is intended (fail loud).
3. CRITICAL: the controller's `current_scope_record` hook MUST return the
   record on the SoD member action. If it returns nil there, the veto is
   silently SKIPPED and the initiator can approve. This is the load-bearing
   control — verify it, don't assume it.
4. Write the verification test and run it:
   - grant the initiator a role that ticks approve
   - POST the approve action as the initiator
   - assert response :forbidden AND
     response.headers["X-Current-Scope-Reason"] == "sod_veto"
   If the reason is "no_grant" instead, SoD is not examining this action.
5. Do NOT add bypass logic unless explicitly asked. If a conditional
   self-approval is a real requirement, use the engine's break-glass
   (allow_sod_bypass) — never a hand-rolled branch, because break-glass
   records the sod.bypassed audit event a hand-rolled branch forgets.
   That recording requires config.audit enabled (the default); if an
   unaudited bypass must be impossible, set config.audit = :strict.
```

## Debug a CurrentScope 403

```text
A request is being denied. Diagnose it from the engine's own signals; do not
guess or bypass the gate.

1. Read the X-Current-Scope-Reason response header (or the INFO log line
   "[CurrentScope] denied <key> (<reason>) → 403"). Map the reason:
   - no_grant          → nothing grants this controller#action key; check
                         the role grid / seed the grant
   - sod_veto          → the subject initiated this record; that denial is
                         the anti-fraud control working — do not "fix" it
   - model_undeclared  → the controller needs `def current_scope_model = <Model>`
   - model_invalid     → current_scope_model returned something that is not
                         a concrete ActiveRecord class
   - impersonation_gate→ non-GET/HEAD while impersonating; sessions are
                         read-only by design
   - not_full_access   → the management UI; only full-access subjects enter
2. In development/test, check the log for the engine's nudges (nil SoD
   record, inert scoped grant, cross-controller key derivation) — each
   names its one-line fix.
3. If there is no header and no log line, a host rescue_from may have
   replaced the denial handler, or the controller never included Guard —
   run `bin/rails current_scope:ungated` to check the gated surface.
```

## Migration tooling (shipped)

Migrating from Pundit? The
[`current-scope-migrate`](https://github.com/davidteren/current_scope/tree/main/.claude/skills/current-scope-migrate)
Claude Code skill is shipped ([#45](https://github.com/davidteren/current_scope/issues/45)
phases 1–2): deterministic policy inventory, decision report, parity
harness, reviewable role-backfill migrations (enum column or rolify), and
safe mechanical call-site rewrites behind an explicit `--write`. The manual
path remains the
[adoption guide](https://github.com/davidteren/current_scope/blob/main/docs/guides/adopting-in-an-existing-app.md).

## Planned agent surfaces

These are tracked but **not shipped** — do not prompt an agent to use them
yet:

- Exposing the subject's abilities to a separate JS front-end (React/Next):
  [#96](https://github.com/davidteren/current_scope/issues/96), Inertia
  props: [#97](https://github.com/davidteren/current_scope/issues/97).
- #45 phase 3: CanCanCan and Action Policy support for the migration
  skill.
