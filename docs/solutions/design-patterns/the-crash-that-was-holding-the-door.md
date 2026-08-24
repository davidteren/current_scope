---
title: "The crash that was holding the door: a degraded read makes a guard answer 'nobody'"
module: lib/current_scope/full_access_lock.rb
date: 2026-08-24
problem_type: design_pattern
component: service_object
category: design-patterns
severity: critical
applies_when:
  - "Changing a read path from raise to nil, or adding an inert_on_error: style option to a lookup"
  - "Writing or reviewing a guard that asks 'is anyone else still holding this' before a destructive action"
  - "A crash, a 500, or an exception is the only thing keeping an operator away from destructive controls"
  - "A blindness check reads a latched error or a per-request marker instead of attempting the real lookup"
  - "One refusal answer covers more than one cause and the operator sees a single message"
symptoms:
  - "A resilience fix lands and a last-holder guard starts reporting that nobody holds full access"
  - "A guard reads its inputs through a lookup that now degrades to nil, so it can never see a holder and permits the removal it exists to block"
  - "Removing a 500 exposes destructive buttons that no other check was protecting"
  - "A blindness check placed before any resolution passes cleanly, because the per-token failure path has not set its flag yet"
  - "The refusal message names the wrong cause: it says to grant access to another subject when the real problem is that no subject could be read"
root_cause: logic_error
resolution_type: code_fix
related_components:
  - "authentication"
  - "rails_controller"
  - "rails_model"
  - "testing_framework"
  - "lib/current_scope/full_access_lock.rb"
  - "lib/current_scope/polymorphic_registry.rb"
  - "app/models/concerns/current_scope/storable_keys.rb"
  - "app/controllers/current_scope/roles_controller.rb"
  - "test/integration/role_members_test.rb"
tags:
  - "fail-closed"
  - "degraded-read"
  - "absence-of-evidence"
  - "load-bearing-crash"
  - "last-holder-guard"
  - "polymorphic-registry"
  - "console-lockout"
  - "guard-design"
related_issues:
  - "#166 (closed, PR #181, merged as ddcd265): the management console returned a 500 on a poisoned polymorphic registry instead of degrading to inert labels"
  - "#116 (open): Solid v1 docs-and-polish sprint to drop the not-production-ready banner"
---

# The 500 was the guard: ask what a failure was preventing before you remove it

## Context

Issue #166 said the management console returned a 500 when the polymorphic registry was
poisoned. The console is the page an operator opens to find and fix broken grants, and
this gem already upholds a "never 500 the console" invariant with a test for it
(`test/integration/role_members_test.rb:128`, the stale resource type that must not
500). A 500 there removes the tool at the moment it is needed.

The fix (PR #181, merged as ddcd265) is small and correct. `class_for` is the one place
both registry raise paths live, so it took an `inert_on_error:` keyword
(`lib/current_scope/polymorphic_registry.rb:42-52`):

```ruby
def class_for(type, inert_on_error: false)
  return if type.blank?
  raise @polymorphic_registry_error if @polymorphic_registry_error

  resolve_polymorphic_token(type.to_s)
rescue ConfigurationError => e
  raise unless inert_on_error

  CurrentScope::Current.polymorphic_registry_error ||= e.message
  nil
end
```

Labeling callers pass the flag and get nil, so the row degrades to inert through the same
path a stale token already takes (#90). The swallowed cause is recorded on
`CurrentScope::Current` (`app/models/current_scope/current.rb:38`) and the layout prints
it as a banner (`app/views/layouts/current_scope/application.html.erb:58-63`). Writes
never pass the flag: `current_scope_check_storable_keys` calls
`CurrentScope.polymorphic_class(public_send("#{side}_type"))` bare at
`app/models/concerns/current_scope/storable_keys.rb:100`, and the comment above it
(`storable_keys.rb:93-101`) says why in place: degrading here would return nil, hit the
`next if klass.nil?` on line 101, skip the key check, and let a grant save under a
registry that cannot say which class its token names. Reads degrade, writes stay loud.

**The learning is not that fix. It is what the fix revealed.**

Before the change, a poisoned registry crashed the roles pages. The operator could not
reach the Delete or Demote buttons at all. The crash was doing work nobody had assigned
it: it was an access control. Once the page rendered, those buttons were reachable, and
the last-holder guard behind them read its holders through
`current_scope_resolved_record("subject")`, which the same change had just made degrade
to nil (`storable_keys.rb:48` passes `inert_on_error: true`). So the guard saw every
holder as inert, concluded that **nobody** holds full access, and would have authorised
deleting the last full-access role. Permanent console lockout for everyone, introduced by
a fix whose entire purpose was resilience.

A local cubic run on the branch raised it as a P0, before the PR was opened (the PR's own
comments carry no P0, so look for it in the pre-PR gate rather than on #181). Three further review rounds were needed to get the
guard right, and each round is a variant of the same mistake.

## Guidance

### Rule 1: before you make a failing path succeed, name what that failure was preventing

A crash, a 500, a raise, or a refusal often sits upstream of an action nobody has
re-authorised. Removing it re-opens everything downstream of it, and downstream may
include a guard that was never tested because it was unreachable.

The check is mechanical, and it is three questions:

1. **What did callers do when this failed?** Not what they were supposed to do: what the
   stack actually did. A 500 aborts the request before any write. That is a behaviour,
   whether or not anyone designed it.
2. **What becomes reachable once it returns a value?** List the actions on the page, the
   endpoints the failure used to abort, the branches that used to be skipped. In a
   console, the answer is usually every mutating button on the screen.
3. **For each newly reachable action, does its guard still work in the degraded state?**
   The guard reads the same data the failure used to interrupt. Read the guard, do not
   assume it.

Question 3 is the one that bites, because the guard usually looks untouched. `#166`
changed no line of `FullAccessLock`. It changed what `current_scope_resolved_record`
returns, and `FullAccessLock` reads holders through it.

### Rule 2: a guard must distinguish "cannot tell" from "no"

A predicate that answers from a degraded read reports **absence** when the truth is
**ignorance**. In an authorization system, absence reads as permission to proceed:
"no other holder exists" and "I cannot see any other holder" produce the same boolean and
opposite correct actions.

So a guard needs a third state, even when it returns a boolean. In this repo, the guard
does the strict lookup itself instead of trusting the shared reader
(`lib/current_scope/full_access_lock.rb:31-42`):

```ruby
def live_holder?(assignments)
  rows = assignments.to_a
  # STRICT on purpose, unlike every other reader, and once per DISTINCT token
  # rather than once per row. current_scope_resolved_record degrades a registry
  # failure to nil (#166), which for a labeling caller is right and for a guard
  # is a lie: it would report "nobody holds full access" when the truth is
  # "this process cannot tell". So ask the raising path first, and let a
  # collision reach the rescue in the two callers below.
  rows.map(&:subject_type).uniq.each { |type| CurrentScope.polymorphic_class(type) }

  rows.any? { |assignment| assignment.current_scope_resolved_record("subject") }
end
```

Line 39 is the raising lookup: `CurrentScope.polymorphic_class(type)` with no
`inert_on_error:`, which delegates straight to `class_for` (`lib/current_scope.rb:346-347`)
and therefore raises `ConfigurationError` on either registry fault. Line 41 is the
ordinary degrading read, and it is only reached once every distinct token has proved
resolvable. Both mutating entry points wrap it in the refusal, and `live_holder?` itself is
private (`full_access_lock.rb:43`). Be precise about how much that buys, though:
`held_full_access?` (`full_access_lock.rb:82-84`) is public and calls `live_holder?` with
no rescue of its own, so the strict half IS reachable without the refusal half. Nothing
outside the module calls it today, so the invariant currently holds by accident of call
sites rather than by the privacy. A future caller would need its own rescue.

Both public guards turn that raise into a refusal
(`full_access_lock.rb:73-80` and `full_access_lock.rb:95-98`):

```ruby
rescue CurrentScope::ConfigurationError => e
  # The second raise path never latches, so registry_blind? cannot see it
  # before the scan starts. Refuse: unknown is not "nobody". Record the cause
  # so registry_blind? answers true afterwards and the caller can say WHY it
  # refused instead of blaming a last full-access holder that may not exist.
  CurrentScope::Current.polymorphic_registry_error ||= e.message
  true
end
```

Note the direction: `true` means "this would lock the console", so refusing is the
fail-closed answer. Pick the return value that denies, not the one that reads naturally.

`any?` still short-circuits (`full_access_lock.rb:41`), so a genuinely live holder found
early answers the question cheaply. Only a scan that finds no live holder pays for the
whole list, which is exactly the case that has to be certain.

### The three rounds after the P0, each the same mistake one layer down

**Round 1: the guard consulted a flag the failure path never sets.** The first repair
added `registry_blind?`, which reads the process-wide latch and the per-request marker
(`full_access_lock.rb:53-56`). Both are set by something that already happened. The latch
is written by a failed `rebuild!` (`polymorphic_registry.rb:100-103`) and exposed by
`PolymorphicRegistry.error` (`polymorphic_registry.rb:114`); the per-request marker is
written by a labeling lookup that swallowed a cause (`polymorphic_registry.rb:50`). The
second raise path, a live constant disagreeing with the registered owner, is decided per
token at lookup time and never latches. In a `DELETE` request no labeling lookup has run
yet, so both clauses read false and the guard sailed through. qodo and Devin found this
independently. The fix is the strict lookup quoted above: the guard must **cause** the
failure it is testing for, not ask whether someone else has seen one.

**Round 2: the blind refusal fired for objects it does not protect.** Refusing while
blind blocked deleting *any* role, including an unassigned non-full-access role whose
deletion cannot lock anyone out, and it reported that refusal as a last-full-access
problem. The order of the first two lines is now the whole fix
(`full_access_lock.rb:60-66`):

```ruby
def would_lock_console_by_removing_role?(role)
  # full_access? FIRST: a non-full-access role cannot lock anyone out, so an
  # unrelated registry problem must not block ordinary role cleanup, and must
  # not report it as a last-full-access refusal.
  return false unless role.full_access?
  return true if registry_blind?
  return false unless live_holder?(RoleAssignment.where(role: role))
```

A fail-closed guard still has a scope. Establish that the object is in scope before you
apply the refusal, or the guard becomes an outage of its own.

**Round 3: one bare `true` covered two causes.** The guard returns the same value for
"this is the last held full-access role" and "this process cannot read who holds it". The
operator got the same advice for both, and for the second one that advice is impossible
to follow: granting full access to another subject does not help when no subject
resolves. The guards now record the cause before refusing (the `||=` lines above), so
`registry_blind?` answers true afterwards, and the controller picks the sentence
(`app/controllers/current_scope/roles_controller.rb:190-203`):

```ruby
# The guard answers a bare true for two different reasons. Telling them apart
# matters: "grant full access to another subject first" is useless advice when
# the truth is that this process cannot read who holds it (#166).
def full_access_refusal_alert(action)
  if CurrentScope::FullAccessLock.registry_blind?
    "Refusing to #{action} while the polymorphic registry is misconfigured: this " \
      "process cannot tell which subjects still hold full access. Fix the registry, " \
      "then retry."
  else
```

Both mutating paths use it: the demote branch at `roles_controller.rb:104` and the delete
branch at `roles_controller.rb:144`.

## Why This Matters

**The regression was worse than the bug it fixed, and it came from the fix.** A 500 on the
console is bad: the operator loses a diagnostic page and can retry after fixing the
config. Deleting the last full-access role is unrecoverable from inside the product:
nobody can open the console again, so nobody can grant it back. The resilience change
converted a recoverable outage into a permanent one, and nothing in the diff looked like
an authorization change.

**The guard was untested because it was unreachable.** No test covered "delete a
full-access role while the registry is poisoned" before PR #181, because that request
could not get past the page. Coverage numbers said nothing. A path that only becomes
reachable after your change has, by definition, zero tests defending it, and that is the
path most likely to be wrong.

**"Cannot tell" is the state that authorization code forgets.** Every other fail-closed
decision in this engine already handles it: silence at the gate denies, an unprovable
duty-separation veto returns 403, a grant that cannot be proved storable is refused at
write time (`storable_keys.rb:114-125`), and the adoption report counts a pair it cannot
re-check as outstanding rather than ready. The last-holder guard was the one place where
"cannot tell" collapsed into "no", and it collapsed the moment its input started
degrading.

**Three review rounds after the P0 is the signal, not the noise.** cubic found the
original hole; qodo and Devin independently found the unlatched half of the first repair;
cubic found the over-broad refusal and the ambiguous message. Every round was the same class:
an answer produced from a state the code could not actually observe. Once a class repeats,
stop patching the instance and re-read the whole change for other instances of it.

**A helper's contract changes for every caller at once.** `inert_on_error:` was introduced
for labels and preloads. `current_scope_resolved_record` is used by labels, by the cascade
audit (`roles_controller.rb:156-167`), and by the last-holder guard, among others across
the console. Most of them want the nil, because they are rendering a row. The guard cannot
use it, so it asks the raising question for itself before reading. When you add a degrade
to a shared reader, enumerate its callers and sort them into "wants a value" and "wants the
truth". The second group is usually small, and it is always the dangerous one.

## When to Apply

- You are turning any raise, crash, timeout, 500, or hard refusal into a returned value,
  a nil, a default, or a rendered page.
- Your change makes a page, form, or endpoint reachable that an error used to abort.
  List every mutating action on it and read each one's guard.
- You are adding `rescue`, `try`, `safe_`, `_or_nil`, or a keyword like `inert_on_error:`
  to a reader that more than one kind of caller shares.
- A predicate answers "none", "zero", "empty", or "not found" from data that can fail to
  load. Decide what it must return when the load fails, and make that the denying answer.
- A guard consults a cached flag, a latch, or a memoised error to decide whether it can
  trust its inputs. Check that the failure mode you fear actually sets that flag before
  the guard runs.
- A guard refuses. Check that the refusal is scoped to objects it protects, and that its
  message names the cause the operator can act on.

## Examples

### Example 1: the guard that read its holders through the thing you just changed

`FullAccessLock` was not edited by the #166 fix. Its data source was.
`current_scope_resolved_record` resolves a row's subject class first, and line 48 is the
degrade:

```ruby
def current_scope_resolved_record(side)
  klass = CurrentScope.polymorphic_class(public_send("#{side}_type"), inert_on_error: true)
  return if klass.nil?
```

`live_holder?` then asks `rows.any? { |assignment| assignment.current_scope_resolved_record("subject") }`
(`full_access_lock.rb:41`). With a poisoned registry every call returns nil, so `any?` is
false, so `would_lock_console_by_removing_role?` reported that removing the role leaves
other holders, and `roles_controller.rb:122` proceeded to delete.

The test that pins it carries the mechanism in its own comment
(`test/integration/role_members_test.rb:177-179`): the 500 was accidentally guarding the
delete, so now that the page renders, the last-holder rule must refuse rather than read
every holder as inert and conclude nobody holds full access
(`test/integration/role_members_test.rb:180-190`):

```ruby
test "a poisoned registry refuses to delete a full-access role" do
  poison_registry!

  delete current_scope.role_url(@owner_role), headers: as(@owner)

  assert_response :redirect
  assert CurrentScope::Role.exists?(@owner_role.id),
         "a registry that cannot resolve holders must not authorise the delete"
  assert_match(/registry is misconfigured/, flash[:alert].to_s,
               "the operator must be told the real reason, not blamed on a last holder")
```

`poison_registry!` (`role_members_test.rb:19-22`) maps a token `User` does not store and
asserts the rebuild raises, so the latch is real rather than inherited from another test.
The teardown restores the previous config instead of blanking it
(`role_members_test.rb:24-29`), because the latch is a process-wide ivar.

### Example 2: the flag the failure never set

The first repair's `registry_blind?` reads two sources
(`full_access_lock.rb:53-56`):

```ruby
def registry_blind?
  PolymorphicRegistry.error.present? ||
    CurrentScope::Current.polymorphic_registry_error.present?
end
```

`PolymorphicRegistry.error` is the latched rebuild failure
(`polymorphic_registry.rb:100-103`, `:114`). `Current.polymorphic_registry_error` is the
per-request marker, written only when a lookup with `inert_on_error: true` swallowed a
cause (`polymorphic_registry.rb:50`). The unlatched collision sets neither before a delete
request reaches the guard. The unit test pins that the collision truly does not latch, and
its comment records that the assertion has to come **after** both lookups
(`test/polymorphic_registry_test.rb:51-71`):

```ruby
assert_raises(CurrentScope::ConfigurationError) { CurrentScope.polymorphic_class("User") }
assert_nil CurrentScope.polymorphic_class("User", inert_on_error: true)
# AFTER both lookups, which is the only position that proves the claim: this
# collision is decided per token at lookup time and never latches. Asserting
# it before the raise would pass whether or not the raise latched.
assert_nil CurrentScope::PolymorphicRegistry.error, "the owner collision must not latch"
```

The integration test for the same path builds the collision by hand and asserts a clean
redirect, not merely a surviving role (`role_members_test.rb:195-213`):

```ruby
# Refused CLEANLY, not by 500ing: a crash also leaves the role in place, so
# the existence check alone cannot tell the two apart.
assert_response :redirect
assert CurrentScope::Role.exists?(@owner_role.id),
       "a collision the latch cannot see must still refuse the delete"
```

That assertion is itself a small instance of the same discipline: a test whose only claim
is "the write did not happen" cannot tell a working guard from the crash the guard
replaced.

### Example 3: reads degrade, writes do not, and the difference is written down

The same `class_for` serves both sides, and the split is by caller, not by mode.

Reads that must never 500 the console pass the flag:
`current_scope_resolved_record` (`storable_keys.rb:48`) and `polymorphic_class_for`
(`storable_keys.rb:28`), the Rails reverse-resolution hook, which converts a poisoned
registry into the `NameError` every console reader already rescues and carries the cause
in the message (`storable_keys.rb:22-29`, `:35-40`).

The write path does not, deliberately (`storable_keys.rb:93-101`):

```ruby
# Deliberately WITHOUT inert_on_error (#166). This is the write side, and
# degrading here would return nil, hit the `next` below, and skip the key
# check entirely, so a grant would save under a registry that cannot say
# which class its token names. Reads degrade; writes stay loud.
klass = CurrentScope.polymorphic_class(public_send("#{side}_type"))
next if klass.nil?
```

cubic asked for the flag here and the request was declined on the branch, with the reason
left in the code rather than only in the review thread. The integration test pins the
write half (`role_members_test.rb:166-175`): under a poisoned registry
`RoleAssignment.create!` raises, the message names `old_token`, and no row exists.

### Example 4: the second guard, and where the pattern still applies

`would_lose_held_full_access?` (`full_access_lock.rb:90-99`) is the definitions-apply
sibling, called from `lib/current_scope/definitions_document.rb:288` inside the same
transaction as `lock_console_state!`. It has the identical shape: `registry_blind?` first,
then `held_full_access?` (`full_access_lock.rb:82-84`), then the planned-name scan, then
the same rescue. It has no `full_access?` early return, and correctly so: its subject is a
whole document, not one role.

One residual worth knowing. The scoping fix from round 2 is pinned by reading, not by a
test. `test/integration/management_ui_test.rb:148-181` covers the last-holder rules with a
healthy registry, and `role_members_test.rb:180` and `:195` cover the two blind paths for a
full-access role. Nothing asserts that an ordinary non-full-access role can still be
deleted while the registry is blind, which is precisely the behaviour that
`return false unless role.full_access?` restores. If that line is ever reordered, the
suite stays green.

## Related

- [The exit condition nobody can reach](../workflow-issues/the-exit-condition-nobody-can-reach.md): the
  sibling from the same week and the same engine, where "cannot tell" also had to be
  counted on the not-ready side rather than treated as clear. Read the two together: that
  one is about a number that can lie, this one is about a predicate that can.
- [A correction is a rot event](../workflow-issues/a-correction-rots-the-plan-it-fixes.md): the same trap of
  patching an instance while the class survives, seen in plan documents instead of code.
- [A plan is intent to verify, not instructions to follow](../workflow-issues/plan-code-sketches-are-intent-not-code.md):
  why a change that follows its brief faithfully can still be wrong, which is what #166
  was.
- **Issue #166** and **PR #181** (merged as ddcd265): the console degrade, the P0 the
  degrade opened, and the three rounds that closed it.
