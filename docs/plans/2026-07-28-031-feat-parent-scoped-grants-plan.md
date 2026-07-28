---
title: Parent-record resolution for scoped grants - a declared chain the resolver walks - Plan
type: feat
date: 2026-07-28
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: hand-authored
origin: https://github.com/davidteren/current_scope/issues/108
execution: code
validated: 2026-07-28
validation_run: wip/intent-engineering/20260728-174539-7dc0413c
---

# Parent-record resolution for scoped grants - a declared chain the resolver walks - Plan

## Goal Capsule

- **Objective:** let a scoped grant held on a **parent** record satisfy a gated
  action on its **children**, so "Lead of Project 7 approves Project 7's
  reports" is expressible without granting per child and without moving the
  record the separation-of-duties veto reads. Opt-in per model; flat stays the
  default.
- **Authority hierarchy:** this plan → issue
  [#108](https://github.com/davidteren/current_scope/issues/108) and its
  2026-07-28 comment → `docs/ROADMAP.md` §2.3 "Resource hierarchy / cascade",
  which already names this shape, this hook name, and the opt-in posture → the
  settled v0.2 model (`README.md`, `CONCEPTS.md`). Immutable invariants:
  - **the veto keeps reading the declared record.** `sod_decision` runs at
    `resolver.rb:50`, *before* any grant check. Nothing here may move it.
  - **gate and list cannot drift.** `scope_for` is not list cosmetics:
    `record_less_scoped_grant?` calls `scope_for(...).exists?`
    (`resolver.rb:400`), so for `config.collection_read_actions` the
    `scope_for` query **is** the gate. Both arms move together or neither does.
  - **a scoped grant still opens nothing on a destroyed or out-of-scope
    record.** `test/collection_scope_gate_test.rb:579` (AE4) and `:595` (the #65
    general rule) stay green unmodified.
  - **the catalog stays route-derived.** No key is added or removed.
- **Delivery posture:** this moves authorization semantics, so it is a **minor
  bump (0.5.0)**, not a patch. It is additive and opt-in: a host that declares
  no chain sees byte-identical decisions. Contrast plan 030, which shipped as a
  patch precisely because nothing it touched was read by `Resolver#decide`.
- **Validation:** `/ie-validate-plan` run 20260728-174539-7dc0413c returned
  *Revise first* against the draft. All three blocking gaps are resolved in this
  revision; the report is at
  `wip/intent-engineering/20260728-174539-7dc0413c/report.md`.

---

## Problem Frame

A scoped grant binds to exactly one record. `scoped_grant?` binds `resource:`
to that record and asks whether a grant exists (`resolver.rb:282-290`):

```ruby
ScopedRoleAssignment
  .where(subject: subject, resource: record, role_id: roles_granting(permission))
  .exists?
```

So a role held on `Project 7` matches actions targeting `Project 7` and nothing
else. There is no way to say the authority reaches the project's reports, which
is the everyday shape of scoped authority.

### What is verified, against `main` at c532088

Probed in `test/dummy` (`RAILS_ENV=test bin/rails runner`), not assumed. The
dummy already carries the exact shape: `reports.project_id` exists with a
foreign key to `projects`, and `Report#current_scope_initiator` returns
`requested_by`.

```
grant on PARENT Project, asked about CHILD Report: [false, :no_grant]
same grant, asked about the Project itself:       [true, nil]
scope_for(Report) with a parent-only grant:       0 rows
initiator visible on child: "Probe Requester"; on parent: false
```

Line 2 matters as much as line 1: the grant is real and its role ticks
`reports#approve`. The denial is the binding, not a misconfigured fixture.

### One of the issue's premises is imprecise, in the safe direction

The issue says the "declare the parent as the record" workaround **blinds** the
veto: "with the parent as the record, the four-eyes veto never sees the
requester". Probed with `config.sod_actions = %w[approve]`:

```
sod_veto_applies?(child)  = true
sod_veto_applies?(parent) = true
decide with PARENT as the record RAISED:
  CurrentScope::ConfigurationError: Project#current_scope_initiator is not
  defined, but "reports#approve" is a separation-of-duties action ...
```

It does not go quiet. It raises, because `Project` has no initiator hook. The
engine's fail-loud contract already catches this workaround.

The silent shape is one hop further on, and it is the one a host actually
reaches: a host meeting that raise will **add** `current_scope_initiator` to
`Project` to clear it. Then the veto runs, measures the project's initiator, and
never sees the report's requester. The requester can approve their own report
and nothing raises, warns, or logs.

That refines the argument for this feature rather than weakening it. The
workaround's danger is not that the gem lets it through silently; it is that the
gem's own error message points the host at the change that makes it silent. The
message names two fixes and one of them is the trap. **U4 fixes the message.**

### Why report mode does not soften this

The adopting host runs report mode (`config.enforcement = :report`). Report mode
downgrades exactly one reason, `:no_grant`, and this denial *is* `:no_grant`, so
it is downgraded and the host sees only a `would_deny` row for an action their
subject performs today. The grant exists and looks correct in the console.
Nothing distinguishes "needs a grant" from "holds a grant that can never match".

That reading failure is real, and it is why #108 asks for a guardrail. The
guardrail is **not in this plan** — it is a diagnostic over today's behavior,
needs no parent chain to be correct, and its operator-facing design deserves its
own review. Split to **#134**, sequenced first. See Scope Boundaries.

---

## Requirements

- **R1.** A model may declare a parent chain: `current_scope_parent :project`.
  Absent a declaration, resolution is byte-identical to today.
- **R2.** When no direct scoped grant matches, the resolver walks the declared
  chain and matches scoped grants against each ancestor.
- **R3.** **The veto reads the declared record, unchanged.** True by
  construction (`sod_decision` precedes the grant checks) and pinned by a test
  that fails if the ordering is ever moved.
- **R4.** The ancestor query matches only roles that **explicitly tick the key**
  (`roles_ticking`). A scoped `full_access` grant does not cascade. (KTD-2.)
- **R5.** `scope_for` gains the same ancestor arm, under the same
  `roles_ticking` rule, so gate and list still agree by construction. Because
  `record_less_scoped_grant?` calls `scope_for(...).exists?`
  (`resolver.rb:400`), this arm is a **gate** for `collection_read_actions`, not
  only a list. Its direct arm keeps `roles_granting` exactly as today, so
  `full_access` still opens a directly-granted record's collection reads.
- **R6.** The walk is **bounded and cycle-safe**. A bad *declaration* raises
  `ConfigurationError`; over-deep or looping *data* truncates at the ceiling,
  denies (fail-closed), and warns once. See KTD-7 for why the draft's
  raise-on-data rule was withdrawn.
- **R7.** A model that defines an instance method named `current_scope_parent`
  without calling the macro raises on the first decision that would have walked,
  naming the correct form. (Not at boot: detecting it there would mean loading
  every model at boot, which the catalog explicitly refuses to do. Same place
  `sod_decision` raises for a missing `current_scope_initiator`.) The silent
  no-op is the failure this hook's name invites.
- **R8.** Every existing test passes unmodified. Specifically
  `test/collection_scope_gate_test.rb:579` (AE4 destroyed record), `:595` (the
  #65 general rule), `:147` and `:160` (STI base_class binding and the accepted
  sibling collapse).
- **R9.** The residuals are stated where a reader meets them: the README, the
  scoped-roles guide, `docs/site/limitations.md`, the CHANGELOG, and the **role
  editor's full-access label**, whose "every permission, present and future"
  wording becomes false under KTD-2. ROADMAP §2.3 moves to shipped.

---

## Key Technical Decisions

### KTD-1 — Model-declared chain (issue option 1), not a record list or a callback

Option 2 (`current_scope_record` returns `[task, project]`) overloads a hook
that already feeds two consumers wanting different records, which is the
confusion #108 is trying to end. Option 3 (a `scoped_match` callback) moves a
security decision into host code. Option 1 keeps one record authoritative, is
static and greppable, and is the shape ROADMAP §2.3 already committed to.

### KTD-2 — The ancestor query uses `roles_ticking`. `full_access` does not cascade.

`roles_granting(permission)` is
`Role.where(full_access: true).or(roles_ticking(permission))`. It is safe today
only because `scoped_grant?` binds `resource:` to one exact record, so a scoped
`full_access` grant opens exactly that record. The resolver's own comments
return to this repeatedly: an unbound query over a `full_access`-inclusive role
set was #49's P0 escalation.

Reusing `roles_granting` for the ancestor walk would mean one scoped
`full_access` grant on a root record opens **every descendant of that record**,
for every permission. That is the same escalation with a multiplier.

So the ancestor arm uses `roles_ticking(permission)`, in both `scoped_grant?`
and `scope_for`. Cascading reach and cascading privilege are separate decisions,
and a host wanting blanket authority over a subtree can tick the keys.

**The cost, stated because validation caught it:** privilege stops being
monotonic. A role with `full_access` reaches *fewer* records through a parent
chain than a role that merely ticks the key. That is genuinely surprising, and
the mitigation is to make it loud rather than to cascade: R9 amends the role
editor's full-access label, and U5 documents the carve-out by name.

### KTD-3 — Opt-in per model, flat stays the default

Cascade surprises people. ROADMAP §2.3 already decided this, and the
Least-Astonishment rule points the same way: a host that never declares a chain
must not discover one.

### KTD-4 — The macro is defined on `ActiveRecord::Base` via `on_load`, not on `Scopeable` and not as a plain hook method

Validation killed two candidate homes and one candidate shape.

**Not `Scopeable`.** Its own contract (`scopeable.rb:3`) reads "BROWSE-ONLY — it
does NOT gate access", and its `included` hook calls `register_scopeable`, which
would silently add every parent-declaring model to the scoped-role picker.

**Not a plain hook method**, despite every sibling hook
(`current_scope_record`, `current_scope_model`, `current_scope_initiator`,
`current_scope_sod_bypassed?`) being one. This is a deliberate, documented
departure. Those hooks answer per-instance questions, so returning a value is
enough. This hook must also produce a **queryable** key: R5's `scope_for` arm
builds `where(<foreign_key> => granted_ancestor_ids)`, and a method returning a
parent *instance* cannot yield one without loading every candidate row. A macro
naming an association gives both derivations — `record.public_send(name)` for
the walk and `reflection.foreign_key` for the query — from one declaration, so
the two can never drift.

Per this repo's own rule, the surprise is named rather than hidden: the README
and the guide state that this is the one declaration that is a macro, and why.

`ActiveSupport.on_load(:active_record)` is the standard Rails engine idiom for
`acts_as_*`-style declarations, so no host include is needed and no existing
concern's contract is bent.

### KTD-5 — The veto needs no change, and that is worth a test rather than a comment

`decide` runs `sod_decision` at `resolver.rb:50`, before `org_role`,
`scoped_grant?`, and the record-less branch. The chain walk lives inside the
grant checks, so it cannot reach the veto. R3 holds by construction today.
Constructions drift; U2 pins it.

### KTD-6 — `scope_for` extends under the same rule, and it is a gate

`scope_for` answers in ids: `model.where(id: <granted resource_ids>)`
(`resolver.rb:114-118`). The parent-aware version unions that with
`model.where(<foreign_key> => <granted ancestor ids>)`, using the foreign key
KTD-4's declaration provides.

Two constraints validation surfaced:

1. **It is a gate.** `resolver.rb:400` takes `.exists?` of this relation for
   `collection_read_actions`, so the ancestor arm's role set is an
   authorization decision. It is `roles_ticking` (KTD-2), which means the read
   arm keeps honoring `full_access` for *direct* grants (`resolver.rb:340`) and
   does not for ancestors.
2. **Normalize through `base_class`.** The existing arm carries a load-bearing
   comment (`resolver.rb:108-113`): querying the model name instead of
   `base_class` makes the list return nothing where the gate allows. The
   ancestor arm needs the same normalization or STI parents drift gate from
   list.

### KTD-7 — Bound the walk. Declaration errors raise; DATA never does.

**Rewritten after code review falsified the first version.** The draft said
"silent truncation is the failure to avoid" and made the record walk raise
`ConfigurationError` past the ceiling and on a cycle. Three reviewers
independently showed that is wrong, and wrong in the dangerous direction:

1. **It made data a 500.** A `parent_id` loop is two `UPDATE`s and no code
   change. Raising from inside `decide` turned that into a 500 that escapes
   report mode's "never breaks a request" promise, and the message
   ("remove one of the `current_scope_parent` declarations") pointed at code
   that was correct.
2. **It broke the gate/list invariant this plan calls immutable.** The record
   walk raised while `ancestor_scope_for` silently truncated, so a chain deeper
   than the ceiling 500ed the member gate while the collection gate happily
   allowed.
3. **It could not be made symmetric.** The class walk *cannot* raise: a
   legitimate self-referential declaration (`Project belongs_to :parent`) never
   terminates at the class level however shallow the data is.

The rule that holds instead:

- **A bad DECLARATION raises**, at declaration time where only the host's own
  code can reach it: a missing association, a `has_many`, a polymorphic or
  scoped `belongs_to`, a custom association primary key, or a chain declared on
  an STI subclass. Each removes a whole class of gate/list drift rather than
  documenting it.
- **Bad DATA truncates**, in both walks, at the same ceiling — then denies and
  warns once. Truncation is **fail-closed** by construction: fewer ancestors can
  only mean fewer grants match.

`MAX_PARENT_DEPTH = 5` stays a private constant, not a config knob: nobody can
pick a default before a host needs one.

---

## High-Level Technical Design

- **`CurrentScope::ParentChain`** — the single answer to "what are this record's
  declared ancestors?". Reads the declaration, walks it, enforces KTD-7's bound,
  returns ancestors nearest-first. Nothing else walks associations.
- **The `current_scope_parent` macro** — installed on `ActiveRecord::Base` via
  `ActiveSupport.on_load(:active_record)` (KTD-4). Stores an association name.
- **`Resolver#scoped_grant?`** — one ancestor fallback, `roles_ticking`.
- **`Resolver#scope_for`** — the ancestor union, `roles_ticking`, `base_class`.

The `ParentChain` module earns its file because it has two consumers with
different needs (the resolver's instance walk and, for the error message, the
ordered chain) and because the bound must be enforced in exactly one place.

---

## Implementation Units

### U1. `current_scope_parent` and `CurrentScope::ParentChain`

- **Goal:** the declaration and the bounded walk. No resolver change.
- **Requirements:** R1, R6, R7.
- **Dependencies:** none.
- **Files:** `lib/current_scope/parent_chain.rb` (new),
  `lib/current_scope/engine.rb` (the `on_load(:active_record)` install),
  `lib/current_scope.rb` (autoload), `test/parent_chain_test.rb` (new).
- **Approach:** the macro validates at declaration time that the named
  association exists and is a `belongs_to`; it raises otherwise. The walk
  carries a visited set and the depth constant.
- **Patterns to follow:** plan 030's `GatingReflection` — one module owning one
  question, no resolver coupling.
- **Test scenarios:** declared chain resolves; no declaration returns empty;
  a data cycle truncates and warns (it does NOT raise); depth over
  `MAX_PARENT_DEPTH` truncates to the ceiling, warns, and denies;
  a scoped `belongs_to`, a custom association primary key, and a declaration on
  an STI subclass each raise; a declaration naming a missing association raises
  at declaration time; a `has_many` association is rejected; a nil parent
  mid-chain stops the walk and denies (normal data —
  `belongs_to :project, optional: true`); repeated `current_scope_parent` calls
  are last-wins, not silently additive; a model defining
  `def current_scope_parent` without the macro raises on first use (R7).
- **Verification:** `bin/rails test test/parent_chain_test.rb`.

### U2. `scoped_grant?` consults the chain

- **Goal:** the gate half of the feature.
- **Requirements:** R2, R4, R3 (the pin), R8.
- **Dependencies:** U1.
- **Files:** `lib/current_scope/resolver.rb`,
  `test/dummy/app/models/report.rb` (add the declaration),
  `test/parent_scoped_grant_test.rb` (new).
- **Approach:** on no direct match, ask `ParentChain` for ancestors and run one
  query bound to them with `roles_ticking`. Rewrite `scoped_grant?`'s doc
  comment and the class-top ordered-decision comment in this unit, per the
  repo's convention that the governing comment moves with the behavior.
- **Test scenarios:** parent grant opens the child; a sibling project's grant
  opens nothing; a scoped `full_access`-only grant on the parent opens
  **nothing** on the child (KTD-2); direct grants behave exactly as before; the
  SoD pin — the lead holds a parent-scoped grant and is the child's requester,
  assert `:sod_veto` (KTD-5); no declaration means no ancestor query is issued.
- **Verification:** the new test plus the full suite green.

### U3. `scope_for` gains the ancestor arm

- **Goal:** the list half, which is also a gate.
- **Requirements:** R5, R8.
- **Dependencies:** U1, U2.
- **Files:** `lib/current_scope/resolver.rb`, `test/parent_scope_for_test.rb`
  (new), plus assertions added to `test/collection_scope_gate_test.rb`.
- **Approach:** union the existing id-narrowed relation with a foreign-key
  relation over granted ancestor ids, normalized through `base_class` per
  KTD-6.2.
- **Test scenarios:** a parent-scoped grant lists the parent's children and no
  others; gate and list agree on one fixture, asserted through
  `record_less_scoped_grant?` and not only through `scope_for` directly; an STI
  child normalizes through `base_class`; AE4 and the #65 general rule stay green
  unmodified.
- **Verification:** the new test plus `test/collection_scope_gate_test.rb`.

### U4. Error-message and label honesty

- **Goal:** stop the engine pointing hosts at the trap, and stop the console
  overstating `full_access`.
- **Requirements:** R9 (the message and label half).
- **Dependencies:** U2.
- **Files:** `lib/current_scope/resolver.rb` (the `sod_decision`
  `ConfigurationError` message), `app/views/current_scope/roles/edit.html.erb`
  and `new.html.erb` (the full-access label), tests for both.
- **Approach:** extend the SoD message with the third fix this feature creates
  and mark the trap explicitly: declaring `current_scope_initiator` on the
  parent makes the veto measure the parent's initiator, not the child's. Assert
  the message text so it cannot silently drift.
- **Test scenarios:** the message names `current_scope_parent`; the role editor
  label states the non-cascade.
- **Verification:** the message assertion plus a system test for the label.

### U5. Docs, ROADMAP, CHANGELOG

- **Goal:** the residuals stated where a reader meets them.
- **Requirements:** R9.
- **Dependencies:** U1-U4.
- **Files:** `README.md`, the scoped-roles guide under `docs/guides/`,
  `docs/site/limitations.md`, `docs/ROADMAP.md` §2.3, `CHANGELOG.md`.
- **Approach:** document the opt-in, the macro-not-method departure and why
  (KTD-4), the non-monotonic `full_access` carve-out by name (KTD-2), and the
  bound. CHANGELOG names the semantics change and the 0.5.0 bump.
- **Verification:** links resolve; ROADMAP §2.3 no longer reads as a proposal.

---

## Verification Contract

Each mutation must turn a named test red. Run them; do not assume.

| # | Mutation | Must fail |
|---|---|---|
| 1a | `roles_ticking` → `roles_granting` in `scoped_grant?`'s ancestor query | the `full_access` non-cascade gate test (U2) |
| 1b | `roles_ticking` → `roles_granting` in `scope_for`'s ancestor arm | the `full_access` non-cascade list test (U3) |
| 2 | Move `sod_decision` below the grant checks | the U2 veto pin |
| 3 | Drop the cycle guard | the U1 data-cycle test (must truncate, not hang) |
| 4 | Drop the depth cap | the U1 depth test |
| 10 | Drop `cascade: false` from `sod_bypassed?` | the U2 break-glass non-cascade test |
| 11 | Allow a scoped/STI/custom-key declaration | the U1 declaration-guard tests |
| 5 | Extend `scoped_grant?` but not `scope_for` | the U3 gate-and-list agreement test |
| 6 | `current_scope_parent_association`'s default `nil` → `:parent` | the U1 "flat by default" test |
| 7 | Match an ancestor of the wrong type (drop the `resource:` bind) | the U2 sibling-project test |
| 8 | Query the model name instead of `base_class` in the ancestor arm | **not covered** — see below |
| 9 | Ignore an instance-method `current_scope_parent` instead of raising | the U1 method-form test |

**Row 6 was re-specified after the first run.** The draft said "walk the chain
when no declaration is present", and that mutation **survived**: with no
declaration there is no association name, so `reflection_for` returns nil and
the walk's loop body never executes. Removing the early return changes nothing.
Flat-by-default is guaranteed structurally, by the *absence* of a declaration,
plus the class attribute's `nil` default — and mutating that default to
`:parent` does turn the test red. The re-specified row is what actually holds
the guarantee up.

**Row 8 is an honest gap, not a passing row.** The ancestor arm normalizes
through `base_class` exactly as the direct arm does, but the dummy has no STI
model that is also a declared *parent*, so nothing discriminates the mutation.
Manufacturing one means adding a `type` column and an STI hierarchy to
`projects` purely for this assertion. The normalization is already pinned for
the direct arm (`test/collection_scope_gate_test.rb:147`), and it is stated here
rather than quietly counted as covered.

---

## Definition of Done

Suite green (**635 unit + 24 system** on `main` at c532088; **672 unit** after
this work), RuboCop omakase clean, **eight of nine mutations re-run red with row
6 re-specified and row 8 recorded as an uncovered gap** (see the Verification
Contract), R1 through R9 each traceable to a named test, and #108 closed by the
PR.

---

## Scope Boundaries

**In:** the declared chain, the resolver's ancestor fallback, the `scope_for`
ancestor arm, the bound, the two message/label honesty fixes, docs.

**Out:**

- **The unresolvable-grant guardrail.** #108 asks for it, and it belongs; it is
  split to **#134** and its own PR, sequenced first. It is a diagnostic over
  today's behavior, correct without any parent chain, and validation found its
  operator-facing design underspecified in four distinct ways (wording collision
  with #90's "inert", the report task's two-way empty-state guard, which console
  views carry it, and its interaction states). Designing that inside a
  semantics-change PR would rush it.
- Inferring parents from Rails associations without a declaration (KTD-3).
- Cascading `full_access` (KTD-2, reopenable).
- A general ReBAC relationship graph.
- Cascading the veto itself, which stays on the declared record permanently.

---

## Assumptions

- The adopting host's chain is shallow (one or two hops). `MAX_PARENT_DEPTH = 5`
  is generous against that and cheap to raise.
- `belongs_to` covers the declared relationships. `has_one`-inverse and
  polymorphic parents are not supported in this pass and raise at declaration.
- The union query's cost is acceptable at one hop over the host's table sizes.
  Open Question 2 tracks the ceiling.

## Risks

- **The non-monotonic `full_access` carve-out (KTD-2) is the most likely thing a
  reviewer or a host pushes back on.** Mitigation: it is reversible (widening
  later breaks nobody), the reverse is not, and R9 makes it visible in the
  console rather than only in docs.
- **The `scope_for` union is the highest-risk code in the plan**, because it is
  simultaneously a list query and a gate. Mitigation: mutations 1b, 5, and 8,
  and a test that asserts agreement through `record_less_scoped_grant?` rather
  than through `scope_for` alone.
- **Depth over large tables.** A deep chain multiplies the union. Mitigation:
  the bound, plus Open Question 2.

## Open Questions

0. **Should the ancestor grant lookup be memoized per request, and the walk
   short-circuit at the first matching hop?** Review measured a per-record gate
   at 2 -> 5 queries for a two-hop chain, unmemoized, on the per-row path a view
   renders. Deferred to its own issue rather than bolted on here: the org role is
   memoized on `Current` and the scoped arms are not, so this is a pre-existing
   asymmetry the chain makes louder rather than a defect this PR introduces.

1. **Should a scoped `full_access` grant cascade?** KTD-2 says no, and this
   revision commits to no. Reopenable; widening later is backward-compatible.
2. **How far does `scope_for`'s union scale?** Fine at one hop. At depth over
   large tables it may want a recursive CTE, which would be this engine's first
   adapter-specific SQL. Revisit with the adopting host's real numbers.

*(The draft's questions on `max_parent_depth`'s default and on sequencing the
guardrail are resolved: the knob is gone in favor of a constant (KTD-7), and the
guardrail is split out and sequenced first.)*

---

## Sources & Research

- Issue [#108](https://github.com/davidteren/current_scope/issues/108) and its
  2026-07-28 comment (the real-host report-mode bake).
- `docs/ROADMAP.md` §2.3, which named `current_scope_parent`, the opt-in
  posture, and the cycle/unbounded-walk guard before this plan existed.
- `lib/current_scope/resolver.rb`: `decide` (:47-76), `scope_for` (:101-119) and
  its `base_class` comment (:108-113), `scoped_grant?` (:282-290),
  `roles_granting`, the record-less read arm's `scope_for(...).exists?` (:400)
  and its `full_access` rationale (:340), the `sod_decision`
  `ConfigurationError` (:238).
- `lib/current_scope/scopeable.rb:3` — the BROWSE-ONLY contract that rules out
  hosting the macro there.
- `test/collection_scope_gate_test.rb`: AE4 (:579), the #65 general rule (:595),
  STI binding (:147), STI sibling collapse (:160).
- Probes run 2026-07-28 in `test/dummy`, reproduced in the Problem Frame.
- Validation: `wip/intent-engineering/20260728-174539-7dc0413c/report.md`.
- Related: #19/#65 (scoped collection semantics), #29 (SoD and collection
  actions), #73/#74 (SoD blind-spot diagnostics), #90 (inert-grant labelling,
  the split-out guardrail's precedent).
