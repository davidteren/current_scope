---
title: "A correction is itself a rot event"
module: docs/plans
date: 2026-07-16
problem_type: workflow_issue
component: development_workflow
severity: high
applies_when:
  - "A plan's premise, requirement, or proposal is withdrawn or reversed during drafting or review"
  - "Reconciling review feedback into a plan in docs/plans/"
  - "About to report a correction as applied, fixed, or reconciled"
  - "Implementing a plan whose reasoning marks anything WITHDRAWN, superseded, or reversed"
  - "A scripted or find-and-replace edit propagates a correction across a document"
symptoms:
  - "A plan's instruction cites, as authority FOR an action, a requirement the same plan marks WITHDRAWN"
  - "The reasoning half of a plan is corrected; the instruction half still says the old thing"
  - "A correction is reported applied and reviewers keep finding the same stale text"
  - "Reviewers find one defect at N locations; the fix lands at fewer than N"
  - "A scripted substitution reports success and mangles or misses spans it should not have touched"
root_cause: missing_workflow_step
resolution_type: workflow_improvement
related_components:
  - documentation
  - "docs/plans/2026-07-15-029-feat-thread-collection-model-plan.md"
  - "lib/current_scope/resolver.rb"
tags:
  - planning
  - plan-drift
  - unreconciled-correction
  - review-feedback
  - completeness-check
  - privilege-escalation
related_issues:
  - "#66 (merged) - plan 029: R4 withdrawn in the reasoning, still cited as authority in U2's instruction"
  - "#65 (open) - bounded full_access, where the withdrawn R4's consequence 2 now lives"
  - "#56 (merged) - the sibling learning this one extends"
---

# A correction is a rot event: fixing the reasoning leaves the instructions saying the old thing

> **This document is for the moment you change a plan's mind.** Its sibling,
> [a plan is intent to verify, not instructions to follow](plan-code-sketches-are-intent-not-code.md),
> is for the moment you *implement* one. That one asks whether a plan's instruction was ever
> right; this one asks what your own correction just made wrong. If you are reading a plan,
> start there. If you are editing one, start here.

## Context

This repo already carries a document about plans that mislead their implementers:
`docs/solutions/workflow-issues/plan-code-sketches-are-intent-not-code.md` (merged
2026-07-15 in PR #56). Its thesis is that a plan's **instruction** is the half that gets
implemented, and it can be wrong while the prose around it is right — either wrong when
written, or right when written and rotted since. It names four rot modes: superseded
premise, drifted citation, unreconciled correction, orphaned deferral.

Three of those four are stories about **time**. A document is written, it stops moving, the
tree keeps moving, and the gap opens by itself. The check they imply is a check against the
world: is this issue still open, does this citation still resolve, has the thing it calls
"unchanged" changed. The fourth — orphaned deferral — is not about time; that doc is explicit
that it "needs no tree movement at all — it was wrong on the day it was written." But it is
still a claim about something **external**: another plan, which never scoped the work.

This is a fifth mode, and what makes it different is that it has **no external referent at
all**. It is self-inflicted and instant. Nothing outside the document moves, and nothing
inside it was wrong when written. The author's own corrective edit is what creates the gap,
in the same session, in the same file — the moment you fix the reasoning, the instructions
become wrong, and they say nothing about it. Every other mode is a document falling out of
step with the world; this is a document falling out of step with itself.

The specimen is plan 029 (`docs/plans/2026-07-15-029-feat-thread-collection-model-plan.md`,
PR #66, merged 2026-07-15). It plans a security fix to the one grant check in the engine
bound to neither a record nor a type — `Resolver#record_less_scoped_grant?`
(`lib/current_scope/resolver.rb:304-311`). Its first draft proposed that once the branch
binds by type, it could safely read `roles_granting` (`resolver.rb:160-162`), which unions
`full_access` into every permission key. The argument was that binding by `resource_type:`
satisfies the safety condition the helper's own comment stated, as it read at the time
(the 2026-07-16 audit found that wording had itself gone stale — PR #61 had added a third,
non-binding caller — and PR #72 rewrites it to name all three callers and the condition
directly):

> Safe to wildcard full_access here because BOTH callers bind the grant to a record:
> `scoped_grant?` by `resource:`, `scope_for` by `resource_type:`.

The argument was wrong — the word in that comment is **record**, and `scope_for`'s
`resource_type:` is one clause of a subquery whose *output* is record ids, whereas the
record-less branch's `.exists?` discards the id and answers with a boolean. Three reviewers
refuted it. The maintainer had already approved the change on the strength of that argument;
it was withdrawn on the evidence, and what it would have shipped is pinned by an existing
test — `test/collection_scope_gate_test.rb:56-65`, *"a scoped full_access role does NOT open
record-less gates app-wide"*.

That withdrawal is where this learning starts. The withdrawal was done. It was thorough. And
it reached only half the document.

## Guidance

**A correction is an edit that changes what the whole document means. Treat it as one — and
verify it the way you would verify a refactor, by sweeping for the thing you removed rather
than reviewing the thing you wrote.**

### The mechanism

When you fix a document, you are *thinking about the reasoning*. The reasoning is what was
wrong; the reasoning is what you argued about with the reviewer; the reasoning is where you
write the correction down, at length, because you want the next reader to understand *why*.
So the reasoning is what you edit.

The instructions feel like **consequences** of the reasoning. They are not. They are separate
text, written earlier, in a different voice, and nothing propagates. A decision section that
now says WITHDRAWN and an implementation unit that still says "do the withdrawn thing" are
two independent strings in one file, and only one of them is executable.

That asymmetry is the whole trap: the reasoning is the half you are motivated to fix, and the
instruction is the half that ships.

### The check that works

**After any correction, grep the whole document for the withdrawn concept by name, and
classify every single hit as refutation-or-instruction.**

Not "did I fix the section I was thinking about." Not "does the document still contain the
old claim" — it will, and it *should*: a good withdrawal quotes the thing it withdraws. The
question for each hit is which half it belongs to:

- **Refutation** — it names the withdrawn thing in order to argue against it, forbid it, or
  test that it never comes back. Keep it. These are the hits that make the sweep feel like a
  false alarm.
- **Instruction** — it tells someone to do it, lists it as a requirement, asserts it as an
  expected outcome, or scopes work around it. Every one of these is now a defect.

Grepping for **what you changed** is what misses them, because what you changed is already
right. Grepping for **what you withdrew** is what finds them.

Run it **first**, as the first step of the correction, and use the hit list as the worklist.
Running it at the end is running it as a formality — you will have already told someone the
fix is done, and the sweep coming back clean will feel like confirmation rather than the
thing that did the work. On plan 029 that sweep was in fact run at the end, and it did come
back clean; by then reviewers had already found what running it first would have found.

### The failure this replaces

The instinct being corrected here is "fix the places I can think of, then check that the bad
text is gone." That is not verification. It is the same shape as a mechanical de-rot pass run
across this repo's plans earlier the same day (PR #58): a substitution script matched a stale
`file:line` string and rewrote it **inside** an existing backtick span, stranding the tail and
leaving an unterminated code span that a reviewer had to catch. The lesson recorded on that
thread applies verbatim here:

> I ran the script, grepped that the target strings were gone, and took their absence as
> success — without checking what replaced them actually rendered. "The bad thing is gone" is
> not "the good thing is there."

Same shape, twice in one day, one level apart. A correction verified by the absence of the old
text is not verified.

## Why This Matters

**An instruction that contradicts its own reasoning is more dangerous than an uncorrected
plan.** An uncorrected plan is at least coherent — a careful reader who disagrees with it can
argue with it. A corrected plan whose instructions were left behind hands the reader an
authoritative-looking directive that *cites an identifier which says the opposite*, and the
citation lends it authority it does not have. In plan 029 the implementation unit's Approach
read:

> …switch `roles_ticking` → `roles_granting` (R4/KTD-3).

R4 — **143 lines away** in the same document — read `~~The branch reads roles_granting when
the type is known.~~ **WITHDRAWN — see KTD-3.**` The instruction cited the withdrawal as the
authority **for** the thing it withdrew. And the citation was not even reaching far: U2's own
Requirements line, *three* lines above the Approach, still listed R4 among the requirements the
unit advances. Both are in the table below. The withdrawal was 143 lines from the instruction
that contradicted it, which is precisely why "fix the places I can think of" does not reach. An implementer coding that unit literally re-ships
the privilege escalation that PR #49 was written to fix — one scoped `full_access` grant on
one record passing every `#index` and `#create` in the host app, which is reachable with stock
data, and which `resolver.rb:285-294` and `roles_ticking`'s own comment
(`resolver.rb:164-180`, the comment above the method) exist to prevent.

**It was eight locations, not one, and they were not clustered.** The withdrawal reached the
decision section, the requirement, the Mermaid diagram, the Verification Contract and the
Definition of Done. It missed:

| Location | What it still said |
|---|---|
| U2 Goal | "Closes consequences 1 and 2" |
| U2 Requirements | still listed the withdrawn R4 |
| U2 Approach | "switch `roles_ticking` → `roles_granting` (R4/KTD-3)" |
| U2 Patterns to follow | "the bind-then-`roles_granting` idiom" |
| U2 test scenario | asserted the escalation as the **expected** outcome |
| Risks, bullet 1 | "KTD-3 permits `roles_granting`" — the exact inverse of the decision it cites |
| Scope Boundaries | "In scope: … bounded `full_access`" |
| A deferral | premised on a call site the withdrawal put back |

The Risks bullet is worth its own beat. It was *trying* to say "the risk is an implementer
lands `roles_granting` contrary to the decision" — and as written it asserted that the
decision permits the thing the decision exists to prohibit. On a security plan whose
highest-stakes call is precisely that prohibition, that is the sentence a skimmer reads
**instead of** the decision.

The test scenario is the worst shape of all: a plan that instructs you to write a test
asserting the escalation is correct behavior. Implemented faithfully, it produces a green
suite that *pins* the bug.

**The first corrective pass found three of the eight and was reported as fixed.** Five
survived that. What found them was not care; it was several independent reviewers with
different lenses — cubic (three separate threads on PR #66), qodo (one), and three
intent-engineering lenses run locally. The predictability lens scored the plan's
`representation_fidelity` 3/10, which was correct. **No single reviewer found all eight.**
That is the argument for the mechanical sweep: this defect is distributed by nature, and
human attention converges on the section it is already thinking about.

**And note where the reviewers were pointed.** The plan's reasoning was, by then, some of the
best prose in the document — a full table of why the argument was false, an amendment filed
against the origin issue (#50), a follow-up issue (#65) carrying the refutation so the next
reader would not re-derive it. Quality of reasoning is not protection. The better the
withdrawal is written, the more convincing the surrounding instructions look.

## When to Apply

Apply the sweep whenever a document's own reasoning changes under it. Concretely:

- **Always — you strike through, withdraw, reverse, or mark something WITHDRAWN/superseded in
  a document that also contains instructions.** The strikethrough is the trigger. It is the
  cheapest possible signal and it fires on exactly this class.
- **Always — a reviewer refutes a premise and you accept the refutation.** The accepted
  refutation is the rot event. You are now the source of the drift, and it is live from the
  moment you press save.
- **Highest priority — the document is a plan on a security path, or the withdrawn thing was
  a permit.** A stale instruction to withdraw a permission fails closed and someone notices. A
  stale instruction to *grant* one fails open and the suite goes green.
- **Highest priority — the withdrawn thing has an ID (a requirement number, a decision
  number, a ticket).** IDs are what instructions cite, and a citation of a withdrawn ID is
  indistinguishable at a glance from a citation of a live one. Grep the ID as well as the
  concept name.
- **High priority — you have just told someone it is fixed.** "Fixed in <commit>" is the point
  at which the remaining locations stop being looked for. Sweep before you say it, not after.
- **High priority — the correction was applied mechanically** (a script, a find-and-replace, an
  agent pass across a corpus). Absence of the old string is not presence of the right one;
  read the rendered result.

Do **not** skip the sweep because the correction was thorough, recent, or yours. Plan 029's
was all three. Thoroughness is measured on the sections you visited, and the sections you
visited are the ones that were already on your mind.

## Examples

### Example 1 — the instruction citing its own withdrawal as authority

*The reasoning, as committed (plan 029, R4):*

> **R4.** ~~The branch reads `roles_granting` when the type is known.~~ **WITHDRAWN — see
> KTD-3.** The branch keeps `roles_ticking`.

*The instruction, in the same commit, in the unit that implements the fix:*

> **Approach:** … Known → add `resource_type: type.base_class.name` to the query (R6) and
> switch `roles_ticking` → `roles_granting` (R4/KTD-3). Rewrite the method's comment block:
> it currently explains why the branch *cannot* bind … and that reasoning is now inverted.

Both of those shipped in the same file, in the same commit, **143 lines apart** (R4 at line
64, the Approach at line 207). The second one instructs the implementer to *delete the comment
that explains why the escalation is an escalation*.

*Corrected in PR #66's review:*

> **`roles_ticking` STAYS — do not reach for `roles_granting`** (R4 is withdrawn; KTD-3
> explains why it is an escalation, and the Verification Contract mutation-tests exactly this
> swap). … the reason it cannot honor `full_access` (`resolver.rb:285-294`) is **unchanged and
> still correct**.

Note what the corrected instruction does that the original could not: it names the withdrawn
thing *as forbidden* and points at the tripwire. That is the shape an instruction should take
after a withdrawal — the refutation restated locally, not delegated to a cross-reference that
the reader may not follow.

### Example 2 — the Patterns section, where the rot hides best

The same unit's "Patterns to follow" originally read:

> `scope_for`'s `resource_type: model.base_class.name` (`resolver.rb:86-90`) — the query shape
> to mirror; `scoped_grant?` (`resolver.rb:247-255`) for the bind-then-`roles_granting` idiom.

Both citations are to real, correct, currently-shipping code. Nothing here is stale in the
time sense — the tree has not moved, the lines resolve, the methods do what the text says.
The rot is that "mirror this method" now imports the exact property the withdrawal removed:
those two callers may safely read `roles_granting` **because they bind to a record**, and the
record-less branch does not. A pattern citation is an instruction wearing a reference's
clothes. It survived the withdrawal because it does not contain the word "do".

It now reads: *mirror its **filter clause only**, not its `roles_granting`.*

### Example 3 — the mechanical correction, verified by absence (PR #58)

Earlier the same day, a scripted pass replaced stale `file:line` citations across the plan
corpus (PR #58 — its own title says 5 plans while its diff touched 8 plan files,
which is its own small instance of this document's subject).
One target string sat inside an existing backtick span listing seven ranges:

```
`README.md:154-163,200-221,258-272,349-372,391-402,446-448,461-470`
```

The substitution matched the head and rewrote it in place, stranding the tail and leaving the
span unterminated. The pass was verified by grepping that the old strings were gone. They
were gone. The replacement was mangled, and a reviewer found it.

The connection to the rest of this document is not the backticks. It is that both failures
answered the wrong question. "Is the old text absent?" is not "is the new text correct," and
"did I fix the part I was thinking about?" is not "does anything in this document still tell
someone to do the withdrawn thing?" In both cases the right question is a sweep over the
thing you removed, read for what it *does* now, not for whether it is still there.

### Related — two learnings this touches but does not cover

- **Mutation testing is what found the defects no reviewer did**, on the same day. Plan 029's
  Verification Contract requires exactly one such mutation — flip `roles_ticking` →
  `roles_granting` and `test/collection_scope_gate_test.rb:56-65` must go red. That contract
  is the last line of defence for this document's failure mode: if the sweep misses an
  instruction and the implementer follows it, the mutation is what still catches it. It is a
  separate learning with its own evidence.
- **The generalization that caused the withdrawn argument in the first place was itself a
  reapplied lesson.** "Prefer a positive closed set" came out of PR #49 and is correct there;
  reapplied to a predicate gating a *refusal* rather than an allow, it misleads. The better
  generalization is "don't re-derive a condition another component already owns" — which is
  also the rule the withdrawn `roles_granting` argument broke, by re-deriving the helper's
  safety condition instead of reading the one it states. Also a separate learning.

## Related

- [A plan is intent to verify, not instructions to follow](plan-code-sketches-are-intent-not-code.md)
  — the sibling. It owns the implementer's moment and names four rot modes that are all about
  time passing under a static document. This one is the fifth and is not about time: the
  author's own corrective edit is the rot event. Its "check 1" (read the instruction against
  the reasoning in the same section) is the last line of defence when this document's sweep
  is skipped — on plan 029 that is exactly what held.
- **PR #66** — plan 029, where the defect was caught and fixed.
- **PR #56** — the sibling learning.
- **PR #49** — the privilege escalation the withdrawn instruction would have re-shipped.
- **PR #58** — the mechanical de-rot pass whose backtick mangling is Example 3.
- **Issue #65** — bounded `full_access`; carries the refutation that caused the withdrawal.
- **Issue #50** — amended after this, because two of its own "Done when" bullets asked for
  the withdrawn behaviour.
