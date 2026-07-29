# 033 — Report mode must account for a missing `current_scope_initiator` (#133)

Status: **implemented**. This is the decision record, written alongside the
work. Issue [#133](https://github.com/davidteren/current_scope/issues/133) was
filed as a question with three candidate answers and no verdict; this doc says
which was taken, what was refused, and what the result cannot do.

## What / Why / How

**What.** An action listed in `config.sod_actions` that reaches a model defining
no `current_scope_initiator` raises `CurrentScope::ConfigurationError`, so the
request returns 500. It does that under `config.enforcement = :report` exactly as
under `:enforce`.

**Why it matters.** Report mode is sold as the safe survey: turn it on, watch,
change nothing for users. A host in report mode has not committed to the engine
yet — they are running it beside their existing authorization to build an
inventory. A 500 on live traffic is a rollback trigger, and it arrives at the
worst possible moment, because the mistake is invisible until real traffic
reaches that action.

**How, in one line.** The raise stays; what changes is *when* the host finds out.

## The decision

#133 listed three options. The result is **1 + 2, and a deliberate refusal of 3.**

**Option 3 (downgrade the raise in report mode) is refused.** Both readings of it
are worse than the 500:

- *Let the request through.* That executes a separation-of-duties action with the
  four-eyes veto never consulted. It is #73's escalation with the safety catch
  removed, and the subject could be the very person who raised the record.
- *Answer 403 instead.* That dresses a wiring mistake up as an ordinary denial.
  Whoever debugs it goes and stares at the grants, which are fine. Silent
  weakening of a misconfiguration is the pattern this engine keeps getting burned
  by (A5, #62, #90 all have the same shape).

So the 500 stands, and stops being the loudest failure with the least reporting.

**Option 1 — find them at boot.** `CurrentScope::SodPreflight` walks
`config.sod_actions` against the route-derived catalog and, for each routed SoD
action, reads the controller's `current_scope_model` declaration. A declared type
that cannot answer `current_scope_initiator` is logged, once, in one message.

**Option 2 — account for them in the survey.** In report mode the Guard rescues
the `ConfigurationError`, logs the cause and the fix, records an
`access.sod_initiator_missing` ledger row naming the permission and the model,
and re-raises. `bin/rails current_scope:report` gets a section for those rows and
a second, static section for the preflight findings.

The two halves are not redundant. The boot list is a **lead** derived from a
declaration; a ledger row is a **proof** produced by a real request. They cover
different failure modes of each other.

## KTD-1 — The preflight is advisory, and that is not a gap to close later

Which record a member action decides about comes from `current_scope_record`, an
instance method whose value exists only mid-request. "Which model does
`invoices#approve` gate?" is therefore **not statically knowable** — the finding
#134 recorded at length after its route-key heuristic called a working grant dead
in this repo's own dummy.

`current_scope_model` (#50) is the nearest declared fact: the type a controller's
collection actions deal in. Under Rails' resource conventions that is the type
its member actions load too. Good signal; not a proof:

| Direction | Shape | Cost |
|---|---|---|
| False negative | Controller declares no `current_scope_model` (e.g. the dummy's `Admin::ReportsController`) | Absent from the list. The 500 still arrives with traffic — which is what option 2 is for. |
| False positive | Member action loads a different type than the collection lists | Named against the wrong model. Costs a look; can never break an app. |

Both limits are printed **in the output the operator reads**, not filed in a
guide they will not open. That rule comes from `GrantDiagnosis.untargeted_caveat`.

Absent from the list is **not** cleared, and the wording says so.

## KTD-2 — The boot hook is `after_routes_loaded`, and this was measured

The obvious home was `config.to_prepare`, beside
`ParentChain.validate_declarations!`, whose comment says exactly why boot-time
validation belongs there: *a deploy must not boot green and 500 on the first
gated request.*

**It is the wrong hook, and putting it there breaks the whole engine.** The
preflight reads `CurrentScope.catalog`, and the catalog **memoizes** its
derivation. Asking for it before the routes are drawn caches an *empty*
permission set for the life of the process, and every gated request then raises
"…is not in the permission catalog".

Measured in the dummy app, not reasoned about:

```
baseline                       CATALOG=44
preflight on config.to_prepare CATALOG=0
preflight on after_routes_loaded CATALOG=44   (eager_load on and off)
```

`after_routes_loaded` is the one hook where Rails guarantees the route set is
complete, and it re-runs on every routes reload, so a dev edit is re-checked.

The general lesson, worth carrying: **a diagnostic that reads a memoized
derivation can poison it.** Anything else added to boot that touches
`CurrentScope.catalog` must answer this question before it ships.

**The suite does not catch this on its own, and that is the dangerous part.**
Moving the hook to `to_prepare` leaves all 717 tests green, because
`config.sod_actions` defaults to `[]` and the preflight returns before it ever
reads the catalog. The damage lands only on a host that opted into SoD — which
is every host this feature exists for. So the pin is on the CAUSE rather than
the symptom: `test/sod_preflight_test.rb` asserts that running the `to_prepare`
chain leaves the catalog underived. Verified red under the moved hook, green as
shipped.

## KTD-4 — A boot crash found while pinning KTD-2, fixed here

`ParentChain.validate_declarations!` iterated `declared_names` while
`validate_key!` resolved `reflection.klass`. That autoloads the parent model, and
a parent declaring a chain of its own registers itself from its class body —
mutating the Set mid-iteration, which Ruby answers with `RuntimeError: can't add
a new key into hash during iteration`, straight out of `to_prepare`.

That is a boot crash for any host whose declared chain points at another
declaring model. The dummy's `Report -> Project` is exactly that shape; nothing
had ever called `validate_declarations!` in a test, so it had no coverage at all.
The fix is to iterate a snapshot (`declared_names.to_a`), and the consequence — a
class registered mid-pass is validated on the next pass instead — is the
partial-coverage bargain that method already documents. Deterministically pinned
in `test/parent_chain_test.rb`; verified red without the snapshot.

## KTD-3 — Ask the resolver why; never read the exception's message

`Resolver#sod_initiator_missing?` is new and **public**, for the same reason
`sod_veto_skipped?` is public: report mode's diagnosis has to be able to ASK what
the cause was. `sod_decision` now raises off that same predicate, so the raise
and the diagnosis cannot drift apart.

The alternative — matching text in the raised `ConfigurationError` — is the
mistake `Event.missing_events_table?` already exists to prevent, and here it
would decide whether a host is sent after their record hook or their model.
`ConfigurationError` is raised for more than one cause; the Guard rescues the
class and asks the predicate. Pinned: an excluded-controller catalog miss raises
`ConfigurationError` and records no SoD row.

Same rule inside the preflight: `defines_initiator?` asks
`model.new.respond_to?(:current_scope_initiator, true)` — the resolver's own
test, including protected/private definitions and `respond_to_missing?` — rather
than re-spelling it as `method_defined?`. Re-deriving a condition another
component owns is #74's defect, and this repo has paid for it three times.

## Verification contract

| Claim | Pin |
|---|---|
| Default config finds nothing, and never touches a controller | `test/sod_preflight_test.rb` |
| A declared initiator-less model is named | same — `documents#show` → `Document` |
| A declared model that HAS the hook is not named | same — `reports#show` stays silent |
| No declaration ⇒ absent, not cleared | same — `admin/reports#approve` |
| A raising host hook degrades to silence, never to a finding | same |
| `warn!` states its own limits | same — asserts `PARTIAL` |
| Report mode records the row, logs the fix, and still raises | `test/integration/report_only_test.rb` |
| Enforce mode records nothing extra | same |
| A `ConfigurationError` from another cause is not diagnosed as this one | same |
| Both report sections print with an empty ledger / from ledger rows | `test/report_task_test.rb` |
| Nothing on `to_prepare` derives the catalog (KTD-2) | `test/sod_preflight_test.rb` |
| Boot-time chain validation survives a mid-walk registration (KTD-4) | `test/parent_chain_test.rb` |

Suite at implementation: **719 unit + 28 system green, RuboCop clean.**

Mutations re-run red before shipping: `sod_initiator_missing?` forced to
`false`; the `report_only?` guard removed from the diagnosis; the boot hook moved
to `to_prepare`; the `to_a` snapshot removed from `validate_declarations!`.

## What this does not do

- It does not make report mode 500-free. It cannot: the veto genuinely has
  nothing to measure, and every alternative to raising is a security regression.
- It does not inspect controllers without a `current_scope_model` declaration.
  Closing that needs the record hook's runtime value — see KTD-1, and #134's OQ-2,
  which is the same limit wearing a different hat.
- It adds **no config knob.** The check is log-only and a no-op until a host opts
  into SoD, so there is nothing to switch off that silence would not already give.
