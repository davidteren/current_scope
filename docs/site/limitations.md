---
title: Limitations
nav_order: 8
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

### A5 — Org grant + nil SoD record skips the veto

On an SoD-listed **member** action, if `current_scope_record` returns `nil`
(or a non-record), the veto has no initiator to measure and is **skipped**.
An org-wide grant can then allow the initiator through.

**Host should:** always return the AR record on SoD member actions. Dev/test
nudges (`warn_on_nil_sod_record`) and report-mode `access.sod_blind_spot`
surface the mistake. See the
[SoD guide](separation-of-duties.html).

### A2 — `actor_method` is only loud at boundary APIs

Without `config.actor_method`, the engine cannot see impersonation. SoD
`sod_identity = :either` and the mutation guard need it. We do not auto-detect
Pretender (or similar) wiring — false auto-detect would be worse than silence.

**Host should:** set `actor_method` when you impersonate; include the
[security checklist](security-checklist.html) item. Doctor/DX skill (#46) may
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

Report mode relaxes **only** `:no_grant`. Mis-declared collection models still
403 with a reason header (and a dev nudge). That is deliberate — a retrofit
must not wave through "you forgot the type hook" as an observation row.

**Host should:** declare `current_scope_model` (and a valid AR class) on
collection controllers that need scoped grants.

### GatingTripwire is opt-in

Controllers that never include `Guard` are not auto-gated. Auto-including on
every Metal controller would surprise hosts.

**Host should:** include Guard on app bases you care about, and optionally
`GatingTripwire` / `bin/rails current_scope:ungated` for inventory. Recommended
on the [security checklist](security-checklist.html).

### No parent/child cascade

A scoped grant on a Project does **not** open Tasks under that project.
Hierarchy is an open design question (ROADMAP / #108), not a silent partial
feature.

## Related

- [Security checklist](security-checklist.html) — deploy footguns
- [Upgrading](upgrading.html) — silent posture flips between versions
- [Solid-solution worklist Track 8](https://github.com/davidteren/current_scope/blob/main/docs/reviews/grok-whole-app-2026-07-19/08-solid-solution-worklist.md)
  — source residuals table
