---
title: "A plan is intent to verify, not instructions to follow"
module: docs/plans
date: 2026-07-15
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - "Implementing any plan in docs/plans/ (artifact_contract: ce-unified-plan/v1)"
  - "A plan's Key Technical Decisions section carries a directional code sketch"
  - "A plan defers to another issue, or to another plan, for part of its correctness"
  - "Implementing a plan drafted before other plans in the same batch merged"
  - "A plan's instruction contradicts its own reasoning, or reuses a helper without stating what makes that safe"
  - "Implementing any of the plans from the 2026-07-15 drafting pass that remain open"
  - "Reviewing a PR that implements a plan on a security-sensitive path"
symptoms:
  - "Green test suite; implementation review still catches privilege escalations"
  - "A plan asserts implementation-ready and its premises have since expired"
  - "A plan defers work to an issue that is open, whose plan never scopes that work"
  - "Shipped code follows the plan faithfully and is still wrong"
  - "A duck-type negation admits an open set where a closed set was meant"
  - "A sketch keys an identifier off one thing while the component reading it keys off another"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
related_components:
  - documentation
  - testing_framework
  - "lib/current_scope/resolver.rb"
  - "lib/current_scope/permission_catalog.rb"
tags:
  - planning
  - plan-staleness
  - plan-coupling
  - code-sketch
  - ce-unified-plan
  - implementation-review
  - privilege-escalation
  - fail-closed
  - plan-drift
related_issues:
  - "#19 (closed, PR #49) — plan 001: KTD-3 negation and KTD-4 helper reuse"
  - "#20 (closed, PR #52) — plan 002: bare literal sketches, no directional hedge"
  - "#21 (closed, PR #53) — plan 003: KTD-2 controller-path keying"
  - "#50 (open) — the residual this class of drift left behind"
  - "#24-#46 (open at time of writing) — the plans this learning is addressed to"
---

## Context

`docs/plans/` holds 31 plans, all carrying `artifact_contract: ce-unified-plan/v1`; 28 of them (`2026-07-15-001` … `-028`) were drafted in a single pass and landed together in PR #47 (`80180da`, merged 2026-07-15 07:38 UTC). Each plan states its reasoning as prose in a **Key Technical Decisions** section, and most also carry a Ruby **code sketch** in an Implementation Unit — explicitly labelled directional ("Directionally:" in `2026-07-15-003-fix-bypass-sod-ungrantable-plan.md:78`).

Five have since been implemented and merged: plan 001 → issue #19 → PR #49, plan 002 → #20 → PR #52, plan 003 → #21 → PR #53, plan 004 → #22 → PR #54, plan 005 → #23 → PR #55. The rest of the batch (issues #24-#46) was open when this was written.

> **Counts here are a snapshot, and they were already wrong once.** The first draft of this document said "25 of the 28 remain" and listed `#22-#46` as open. Both were false *at the moment it was committed* — #22 had merged 57 minutes earlier and #23 twenty-three minutes earlier. The document about plans going stale went stale inside its own drafting window, and shipped that way into the PR that introduced it. That is not an embarrassing aside; it is the second half of the learning, and it has its own section below. Trust the issue tracker over any number written here.

Implementing those three surfaced a repeating failure mode: **an instruction in the plan was wrong, and it was the instruction — not the reasoning around it — that got implemented.** The defects were not caught by the test suite. They were caught by review, and two of them were privilege escalations.

Be precise about the shape, because it decides which check finds it. In two of the three, the plan contained its own correction — a premise a line or two from the instruction that contradicted it, so reading the KTD against itself was enough. In the third it did not: KTD-4 said only "reuse this helper", the reuse was wrong, and **nothing in the plan said otherwise**. Only reading the helper's definition finds that one. A rule of "check the sketch against the prose" would have caught two of these three and missed the one that caused the worse escalation.

The evidence is in PR #49's own commit list, where the defect and its correction are both visible in-branch:

```
f2d6e644 fix(resolver): a record-less target honors scoped grants
...
4c2b5fc2 fix(resolver): test record-less positively, closing a fail-open
4f3828cd fix(resolver): a scoped full_access role must not open record-less gates
b6a97ec5 fix(resolver,guard): close three more record-less holes found in review
```

`f2d6e644` implemented the sketch faithfully. `4c2b5fc2` and `4f3828cd` undid it.

> **On the SHAs in this document.** Every PR here was squash-merged, so these
> in-branch commits are unreachable from `main` — `git show f2d6e644` will fail
> on a fresh clone. They are cited as historical evidence and are readable in
> the PR's own commit list on GitHub (#49). The same applies to `aa82d16` below:
> it is the pre-review draft of the plans branch, squash-merged as #47. The
> durable references in this doc are the **PR numbers** and the **file:line**
> citations against the current tree.

## Guidance

**Before implementing any KTD, re-derive its instruction from the plan's own reasoning *and* from the real code. Both, every time — the plan cannot catch the defect it doesn't know it has.**

Three checks. Do all three: check 1 is the cheapest and catches two of the three verified defects, but the one it misses is the one that caused the worst escalation.

**1. Diff the instruction against the reasoning in the same KTD.** The reasoning carries the argument; the instruction is a convenience, and it is written second. When they disagree, the instruction lost information — and the disagreement is a defect report, not an ambiguity.

Plan 001's original KTD-3 (at `aa82d16`, pre-review) contained both halves in one paragraph:

> A collection action gates with `record: nil`; a class-form check (`allowed_to?(:create, Report)`) gates with a `Class`. Both mean "no specific instance." The branch keys on "not an instance" (`!record.respond_to?(:new_record?)`) …

The prose names a **closed set of exactly two shapes** — `nil`, or a `Class`. The instruction encodes the **negation**, which admits an open set: `String`, `Integer`, `Symbol`, any PORO. That gap is the whole bug, and it is legible without reading a line of `lib/`.

**2. Read the definition of anything the instruction reuses — not what its name implies.** This is the one check 1 cannot stand in for, and skipping it is what shipped the worse of the two escalations. `roles_granting` is an honest name for what it does; nothing about the name or the plan says it unions `full_access` into every key, and nothing about the plan said the new branch couldn't afford that. Only the definition says it.

The question to ask is not "does this helper do what I want?" but **"what makes it safe for the callers it already has, and does my call site have that property?"** `roles_granting` was safe only because both existing callers bound the grant to a record. The new branch bound to neither, and the helper had no way to say so.

**3. Check any key the instruction constructs against what the *reader* of that key computes.** A key written by one component and read by another must be derived the same way at both ends, and the two ends are usually in different files by different reasoning.

The shipped resolver now encodes all three corrections, with the reasoning inlined so it survives the next reader (`lib/current_scope/resolver.rb:248-255`):

```ruby
def record_less_scoped_grant?(subject:, permission:, record:)
  return false unless record.nil? || record.is_a?(Class)
  return false if sod_action?(permission)

  ScopedRoleAssignment
    .where(subject: subject, role_id: roles_ticking(permission))
    .exists?
end
```

### The pattern to name: the sketch reaches for what's in hand; the prose names what's required

All three defects share one shape, and it holds up under a direct reading of the tree: **the sketch answers an adjacent question — one whose answer was already lying around at the point of writing.**

| KTD | The question that needed answering | The question the instruction answered | What was "in hand" | Was the right question stated in the plan? |
|---|---|---|---|---|
| 001 KTD-3 | "is this `nil` or a `Class`?" | "is this not an AR instance?" | `respond_to?(:new_record?)` — already the idiom at `resolver.rb:137` (`sod_decision`) and `resolver.rb:194` (`scoped_grant?`) | **Yes** — its own premise, one sentence earlier: *"Both mean 'no specific instance.'"* |
| 001 KTD-4 | "did someone explicitly tick this key?" | "does this role satisfy this key?" | `roles_granting` — an existing helper backing two callers | **No.** Nowhere. KTD-6 and R8, which say this, were *written during review* — after the escalation shipped |
| 003 KTD-2 | "what record is this about?" (`route_key`) | "where did the request go?" (controller path) | `controller` — already the loop variable from `key.split("#")` | **Yes** — its own opening sentence names `model_name.route_key` |

Each wrong answer is *cheaper to write* and *usually agrees* with the right one. That is what makes the pattern durable rather than sloppy: the instruction is not careless, it is economical, and its economy is exactly what drops a distinction that was being drawn — sometimes a line above it, and sometimes nowhere at all.

**The last column is the important one.** Two of these are legible from the document; one is not. KTD-4 is the one that turned a single scoped grant into app-wide access, and no amount of re-reading the plan would have found it, because the plan agreed with itself. That is why the checks below are ordered the way they are, and why check 2 is not optional.

## Why This Matters

**A green suite is not a defence here.** All three defects passed. Their tests asserted the story the plan told (a scoped subject reaches their index; a bypass cell renders); none asserted the story's boundary (what happens when the target is a `String`; when the role is `full_access`; when the controller is namespaced). A sketch that answers an adjacent question passes every test written for the primary question.

**Two of the three were privilege escalations, in an engine whose stated posture is fail-closed.**

- *001 KTD-3:* a host whose `current_scope_record` returns `params[:id]` (a `String`) hands the gate a non-record. Under the negation, that lands in the record-less branch and is **allowed** on the strength of a scoped grant held over a *different* record — inverting the branch's own invariant, that a grant on X must not act on Y.
- *001 KTD-4:* `roles_granting` unions `Role.where(full_access: true)` into every key (`resolver.rb:100-102`). Reused in a branch that binds to no record, one scoped `full_access` grant on one record passes **every** `#index` and `#create` in the host app — including keys that don't exist. Reachable with stock data: `seed_defaults!` ships a full_access `Owner` role.

**"Directional" does not protect the sketch — it advertises it.** Marking a sketch directional reads as *close enough*, which is precisely the register in which it gets pasted. The label describes the author's intent, not the reader's behaviour.

**The plan's own guardrail was silent — and that is the strongest evidence here, not a footnote.** Plan 001's Goal Capsule carries stop condition (b): *"any change would alter a decision on a persisted-record target."* It sounds like it should have fired on the negation. It could not have: `String`, `Integer` and PORO targets are, by definition, not persisted records, so every persisted-record decision stayed byte-for-byte identical. That is requirement R5, and **R5 held**. The escalation walked straight between a correct stop condition and a passing requirement, and the suite was green for exactly the same reason.

A guardrail phrased around the case you thought of does not cover the case you didn't. The invariant actually breached was the branch's own — *a grant on X must not act on Y* — which no stop condition named.

**None of this is an argument against planning.** In two of the three the plan carried the reasoning that identified its own defect, and the review that caught the escalations was largely reading the plan's words back against the code. The plans are load-bearing; the instructions inside them are the soft spot.

## When to Apply

Apply on **every** KTD carrying a code sketch, before writing the implementation. Concretely, treat these as escalating signals:

- **Always** — a plan in `docs/plans/` labels its sketch "Directionally:" or "directional". That's the marker for this whole class.
- **Highest priority** — the sketch is a **predicate on a security path** (a gate, a resolver branch, a grant check). Every one of the three verified defects was a boolean, and two escalated. Predicates are where an adjacent question is cheapest to write and costliest to be wrong about.
- **Highest priority** — the sketch **reuses an existing helper** and the plan says so approvingly ("reuses … so it stays expressed in exactly one place"). Reuse is normally correct; here it silently imports the helper's *other* callers' assumptions. Read the helper's definition and ask what makes it safe **for its current callers** — then check the new call site has that same property. `roles_granting` was safe only because both callers bound the grant to a record.
- **High priority** — the sketch **constructs a key, path, or identifier** that a *different* component reads. Verify both ends derive it identically.
- **High priority** — a **negative/duck-type test** stands where the prose describes a closed set. Prefer the positive test; a negation is a claim about everything that will ever exist.

Do **not** skip the check because the sketch matches the existing idiom in the file — in 001 KTD-3 the sketch matched two neighbouring methods (`resolver.rb:137`, `:194`) and was still wrong, because those methods fell through to a deny and the new branch fell through to an allow.

## Examples

### Example 1 — negation vs. closed set (plan 001 KTD-3 → PR #49)

*Before (the sketch, plan 001 at `aa82d16`):*

```ruby
def collection_scoped_grant?(subject:, permission:, record:)
  return false if record.respond_to?(:new_record?) # a specific instance → scoped_grant? owns it
  ScopedRoleAssignment
    .where(subject: subject, role_id: roles_granting(permission))
    .exists?
end
```

*After (shipped, `lib/current_scope/resolver.rb:248-255`):*

```ruby
def record_less_scoped_grant?(subject:, permission:, record:)
  return false unless record.nil? || record.is_a?(Class)
  return false if sod_action?(permission)

  ScopedRoleAssignment
    .where(subject: subject, role_id: roles_ticking(permission))
    .exists?
end
```

The regression is now pinned by a test that enumerates the open set the negation admitted (`test/collection_scope_gate_test.rb:157-166`):

```ruby
test "R5: a non-record target fails CLOSED, never open" do
  # Alice is scoped on @report ONLY, and holds no org grant.
  scope_grant(@alice, role("Editor", "reports#show"), @report)

  [ @other.id.to_s, @other.id, :garbage, "anything", 42, {}, [], Object.new ].each do |target|
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: target),
      "a #{target.class} target must never be treated as record-less — it would grant " \
      "access off a scoped grant held over a different record"
  end
end
```

The plan doc on `main` now carries the correction folded back into KTD-3 (`docs/plans/2026-07-15-001-fix-scoped-collection-gate-plan.md:53`), including the sketch at `:99-107`.

### Example 2 — the reused helper that imports its callers' assumptions (plan 001 KTD-4 → PR #49)

*Before (plan 001 KTD-4 at `aa82d16`):*

> It reuses the existing `roles_granting(permission)` helper that already backs both `scope_for` and `scoped_grant?`, so "does a role grant this key?" stays expressed in exactly one place.

*The defining source (`lib/current_scope/resolver.rb:100-102`):*

```ruby
def roles_granting(permission)
  Role.where(full_access: true).or(Role.where(id: roles_ticking(permission)))
end
```

Safe for `scoped_grant?` (binds by `resource: record`, `resolver.rb:197`) and `scope_for` (binds by `resource_type:`, `resolver.rb:88`). The record-less branch binds to neither. The fix extracted `roles_ticking` and expressed `roles_granting` in terms of it — the corrected plan doc now says so at KTD-6 (`:55`).

**The sharpest instance of the lesson is here.** Even the *corrected* sketch is still not what shipped. Plan 001 lines 109-112:

```ruby
# Explicit ticks only; full_access deliberately not unioned in (KTD-6).
def roles_ticking(permission)
  RolePermission.where(permission_key: permission).select(:role_id)
end
```

Shipped, `lib/current_scope/resolver.rb:121-126`:

```ruby
def roles_ticking(permission)
  RolePermission
    .where(permission_key: permission)
    .where.not(role_id: Role.where(full_access: true).select(:id))
    .select(:role_id)
end
```

The `where.not` is missing from the sketch, and the shipped comment (`resolver.rb:112-115`) explains why it cannot be: *"The `where.not` is load-bearing, not belt-and-braces: a role can be full_access AND retain explicit rows (tick grid cells, then flip the full-access toggle), and matching on the leftover row alone would walk it straight back through the branch full_access is barred from."* That case has its own test — `test/collection_scope_gate_test.rb:70`, *"a scoped full_access role with explicit permission rows is still barred"*.

So: a sketch corrected in review, by the person who found the bug, still under-specified the fix by one clause. **Re-derive from the prose and the source every time — including from a sketch that has already been through review.**

### Example 3 — a live landmine: plan 003's sketch was never corrected

Plan 003's KTD-2 prose is right, and is unchanged from `aa82d16` to `main` (`docs/plans/2026-07-15-003-fix-bypass-sod-ungrantable-plan.md:63`):

> The resolver resolves the bypass key against the record's `model_name.route_key`, which for a conventional resource controller equals the controller name.

Verify that against the source. `sod_bypassed?` calls `CurrentScope.allowed?(CurrentScope.config.sod_bypass_permission, subject: initiator, record: record)` (`resolver.rb:188`) with **no `controller_path:`**. `allowed?` builds the key via `permission_key(action, record: record, controller_path: nil)` (`lib/current_scope.rb:77-84`), and `permission_key` with no `controller_path` returns `"#{route_key}##{action}"` (`lib/current_scope.rb:99-105`). So for the default bare-action form the key the resolver reads is derived from the **record**. (A host that configures the full-key form instead gets it used verbatim — that path is not record-derived, and the catalog tolerates it.)

The sketch in U1 said — and, for eleven days after PR #53 corrected the code, still said:

> for each, add `"#{controller}##{bypass_action}"`.

where `controller` comes from `key.split("#")` on the routed keys, which are built as `"#{controller}##{action}"` from `route.defaults[:controller]` (`lib/current_scope/permission_catalog.rb:32-39`) — i.e. the **full namespaced path**. For the dummy app's plain `ReportsController` the two agree, and every test written against it passes. For `Admin::ReportsController` the sketch injects `admin/reports#bypass_sod` while the resolver reads `reports#bypass_sod` — break-glass ungrantable for every namespaced SoD controller, and an admin handed a grid cell that silently does nothing.

*Shipped (`lib/current_scope/permission_catalog.rb:84-95`):*

```ruby
def bypass_keys(routed)
  return [] unless CurrentScope.config.allow_sod_bypass

  sod_actions = CurrentScope.config.sod_actions
  return [] if sod_actions.empty?

  routed.group_by { |key| key.split("#").first }
        .filter_map { |controller, keys|
          actions = keys.map { |k| k.split("#").last }
          "#{controller.split('/').last}##{bypass_action}" if actions.intersect?(sod_actions)
        }
end
```

Pinned by `test/permission_catalog_test.rb:163-168`, *"a namespaced SoD controller injects the record's key, not its own path"*.

**Actionable for whoever picks up the rest.** Plan 003's U1 sketch contradicted both its own KTD-2 prose and the code that shipped in PR #53, and nothing folded the correction back — the plan kept handing out the wrong answer while the repo held the right one. PR #56 (the one that introduced this document) fixed it, along with plan 001's under-specified `roles_ticking` and plan 024's wrong issue link.

Do not read that as "the plans are clean now." Those three were found because this learning went looking for them. Assume the rest are in the same state — drafted in one pass, reviewed as prose, instructions unverified against a tree that has since moved under them by five merged PRs.

> **This paragraph is a specimen too.** Its first draft said plan 003's sketch was *"still on `main` today, uncorrected"* — in the same PR that corrected it. Review caught that the claim would be false the moment it merged, sending readers after a landmine that no longer existed. A document about work going stale, going stale against its own diff. The lesson is not "be more careful": it is that **a claim about the present tense of a repository is a claim with an expiry date**, including the ones written by someone who has just spent a day learning exactly that.

That last clause is the hinge, and it earns the section that follows: a plan can also be **right when written and wrong by the time you read it**. That is a different defect with a different check, and the sketch checks above will not find it.

---

## The other half: a plan can be right when written and wrong when you read it

Everything above is about an instruction that was **wrong when written**. There is a second defect with the same symptom and a different cause: an instruction that was **correct when written**, and expired.

Both fire at the same instant, for the same reader, on the same task — *"I am about to implement a plan from `docs/plans/`."* They are one checklist, not two. (Two partial checklists at one moment is the failure this document's own guardrail section warns about.)

### The trigger case: plan 006 dated its own expiry, and nothing ran it

Plan 006 (issue #24) documents what a denial renders. It was accurate the morning it was written. By the afternoon, four of its statements were false:

| Plan 006 says | Reality after PR #55 |
|---|---|
| "the three denial reason codes" | four — `:not_full_access` was added |
| a denial "renders an empty body" | true for host denials; the engine's UI now renders a page |
| `current_scope_denied` is "deliberately left unchanged" | it changed — it delegates to `current_scope_render_denied(reason)` |
| defers the default's correctness to "#23/#39's job" | **#23 merged before plan 006 was picked up** |

Shelf life under seven hours. No signal — the plan still asserts `artifact_readiness: implementation-ready`, as **all 31 plans in this repo do**, none of them with an expiry.

The plan saw it coming and could not act. Its own Open Questions flag the reason-code set as *"Assumed complete as of 2026-07-15"* and name the exact invalidating event — *"if the resolver adds reasons"*. The resolver added one that day. Its coupling section says that if #23 changes the default, *"revise this section as part of that plan."* #23 did. It didn't.

**A plan cannot enforce its own coupling.** Writing "revise me" into a document does nothing; the revision has to be someone's job at the moment the invalidating change lands, or it doesn't happen.

### Four ways a plan rots

1. **Superseded premise** — it defers to an issue that has since merged, and merged differently than assumed. *(Plan 006 → #23.)*
2. **Drifted citation** — `file:line` references and counts, true at drafting. *(Plan 016: "`docs/plans/` (16 plan files)" against a real 31, and a "580-line README" that is 684.)*
3. **Unreconciled correction** — the code was fixed in review and the plan that produced the defect still says the old thing. *(Plan 003's sketch, until PR #56.)*
4. **Orphaned deferral** — it defers work to another plan that never scoped it. *(Plan 015 defers a README fix to "#25, which owns README edits"; plan 007 is #25's plan, edits the README extensively, and never mentions it.)*

Mode 4 needs **no tree movement at all** — it was wrong on the day it was written, and no amount of waiting reveals it.

### The check

Before implementing, diff the world against the plan's stated assumptions. Minutes of work, and it is what caught plan 006 before a word of it was written:

- **Is every issue it defers to still open?** `gh issue view <n> --json state`. A closed one means the premise resolved — and may have resolved differently than assumed.
- **If the target issue is open, does the target plan actually scope the work?** Grep it. *This is the one the obvious check misses:* plan 015 defers to #25, #25 is open, so "is it still open?" returns a **false green**. The question is not whether the issue exists, it is whether anyone is doing the thing.
- **Do its citations still resolve?** Line numbers and counts drift silently and are cheap to spot-check.
- **Has anything it calls "unchanged" changed?** That phrase is a claim about code the plan does not own.

### Why this is not an argument for planning less

28 plans drafted at once is 28 snapshots of a single moment. The first merge invalidates premises in the other 27 — **that is arithmetic, not sloppiness**, and it gets worse the more of them are in flight at a time. Fifteen of the plans that remained after five merges referenced issues that had since closed.

The fix is not fewer plans. It is to read a plan's assumptions as **claims with expiry dates** rather than as settled fact, and to check them at implementation time — the same way this document says to re-derive its instructions rather than paste them. Same moment, same reader, same reflex.

**Two corollaries worth keeping:**

- **Cite plans by number, not path.** Plan 016 proposes moving `docs/plans/` to `docs/internal/plans/`, and enumerates only the README and STATUS.md as referencing it — an enumeration that was already false when written. A number survives the move; a path does not.
- **A plan claiming `implementation-ready` is claiming it was ready once.** Nothing re-checks it. Treat the field as provenance, not as a warranty.
