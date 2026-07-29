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

**Option 1 — find them before traffic.** `CurrentScope::SodPreflight` walks
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

**What that costs, stated rather than glossed:** the hook only fires during
initialization where routes load during initialization. Railties ends
`set_routes_reloader_hook` with `reloader.execute_unless_loaded if !app.routes
.is_a?(Engine::LazyRouteSet) || app.config.eager_load`, so an eager-loading
environment (production, staging — the environments a bake runs in) warns at
boot, while development's lazy route set defers the warning to the first
request. Forcing the routes early to make "boot" literally true would defeat
`LazyRouteSet` for every host in order to make one log line punctual. Every
"at boot" claim in the docs was corrected to say this. (#133 review)

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
The fix walks in WAVES: take a snapshot, validate it, then take another until no
new name appears. A single snapshot stops the crash but defers whatever
registered mid-pass to a later pass — and in production there is no later pass,
so that would silently drop exactly the declarations the walk itself just
loaded. The loop terminates because the registry is finite. Deterministically
pinned in `test/parent_chain_test.rb`, verified red both without the snapshot
(the crash) and with only one snapshot (the silent skip).

**A first draft of this section justified the snapshot's cost with "production
has eager loaded before this runs." That is false, and the review caught it.**
Railties orders `:run_prepare_callbacks` (which runs `to_prepare`) *before*
`:eager_load!`, with the source comment "This needs to happen before eager load
so it happens in exactly the same point regardless of config.eager_load". So
`declared_names` at that moment holds only the models something else already
loaded — in **every** environment. The consequence is that #108's boot-time
chain validation has always been much thinner than its own comment implies, and
the snapshot neither causes nor worsens that. Closing it needs a second pass
after eager loading, which changes *when* a bad declaration raises and is
therefore its own change, filed as **#139** rather than smuggled into this PR.
The comment in `parent_chain.rb` now says the true thing.

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
| One broken controller does not blind the whole run | `test/sod_preflight_test.rb` |
| An uninstantiable model is passed over, and marks the run degraded | same |
| A NoMethodError from our own code re-raises rather than degrading | same |
| An empty preflight still prints, and says whether it was clean or blind | `test/report_task_test.rb` |
| A failed ledger write names the RAISED outcome, not an allow or a deny | `test/integration/report_only_test.rb` |
| The engine actually WIRES the preflight, and firing the hook warns | `test/sod_preflight_test.rb` |
| A blind run speaks instead of printing nothing | same |
| The fix line leads with the hook, not with disabling the veto | same |

Mutations re-run red before shipping: `sod_initiator_missing?` forced to
`false`; the `report_only?` guard removed from the diagnosis; the boot hook moved
to `to_prepare`; the `to_a` snapshot removed from `validate_declarations!`;
`declared_model_for`'s isolating rescue removed; the diagnosis stopped asking the
resolver and trusted the exception class alone.

## What the review changed, recorded rather than smoothed over

Every item here was wrong in the first version of this branch. Listing them
because this repo's own base rate says review changes the design on every PR,
and a plan that reads as if it arrived correct teaches the next reader nothing.

- **The suite was order-dependent and passed by luck.** The KTD-2 pin calls
  `Rails.application.reloader.prepare!`, which also runs
  `reset_scopeable_registry!` — and in a test process that is permanent, because
  `prepare!` does not unload constants, so no model class body re-runs
  `include CurrentScope::Scopeable`. Eleven picker tests failed on seed 22. The
  pin now snapshots and restores the registry.
- **Two tests could not fail for their stated reason.** The unrelated-
  `ConfigurationError` pin posted to an excluded controller, whose catalog miss
  raises in `current_scope_check!` *before* the rescue it was pinning; and the
  "degrades to silence" pin passed with `declared_model_for`'s isolating rescue
  deleted, because the outer rescue returned `[]` either way. Both rewritten,
  both verified red.
- **"At boot" was false in development**, and appeared in nine places.
- **The `collection_type?` shape guard was re-derived inline** — the #74 defect,
  in a diff whose own plan cites #74 three times. It now asks the resolver.
- **The advisory's caveat named two limits and had four.**
- **An empty preflight printed nothing**, so a check that blew up looked exactly
  like a check that came back clean.
- **Per-controller degrade logging would flood** the multi-tenant host it is
  meant to help; it aggregates into one line per run now.
- **The feature's headline half was unpinned.** A reviewer deleted the entire
  `initializer "current_scope.sod_preflight"` block and the suite stayed green,
  so a bad merge could have removed the boot warning silently. Two pins now:
  the initializer is registered, and firing `:after_routes_loaded` reaches
  `warn!`.
- **`warn!` stayed silent when every check had failed** — the same vacuous
  all-clear the report task had just been taught to refuse, left standing on the
  surface a host reads at deploy time.
- **The fix line offered "remove the action from `config.sod_actions`" as a
  coequal remedy.** On a list that can be wrong, that invites a host to delete a
  fraud control on a false accusation. It leads with the hook now and qualifies
  the removal. The raise in `Resolver#sod_decision` still offers both plainly —
  there the cause is proven.

- **The advisory grew four ivars of run state**, one per honesty fix, and three
  independent reviewers (cubic, ie-predictability, ie-architecture) landed on
  that seam. `SodPreflight` is stateless now: `scan` returns a `Result` carrying
  `rows`, `inspected`, `in_scope` and `skipped`, and every honesty question
  (`degraded?`, `blind?`) is a method on that value. This is a NET DELETION —
  it removed the four ivars, the fail-closed "never run" special case, the
  temporal-coupling comment, and the capture-at-call-site workaround in the rake
  task, because you cannot ask a result you do not have.
- **The `ParentChain` snapshot deferred work to a pass that does not exist.**
  cubic caught that a model registering mid-walk waited for "a later pass",
  which production never runs. It validates in waves now.

Suite after the review pass: **734 unit + 28 system green, RuboCop clean**,
stable across seeds.

## What this does not do

- It does not make report mode 500-free. It cannot: the veto genuinely has
  nothing to measure, and every alternative to raising is a security regression.
- It does not inspect controllers without a `current_scope_model` declaration.
  Closing that needs the record hook's runtime value — see KTD-1, and #134's OQ-2,
  which is the same limit wearing a different hat.
- It adds **no config knob.** The check is log-only and a no-op until a host opts
  into SoD, so there is nothing to switch off that silence would not already give.
