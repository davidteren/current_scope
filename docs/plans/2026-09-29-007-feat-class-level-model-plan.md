---
title: Class-Level Model Declaration - Plan
type: feat
date: 2026-09-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/142
---

# Class-Level Model Declaration - Plan

Issue #142 asks for an optional class-level `current_scope_model` so SoD preflight does not instantiate the controller when the model is constant.
The instance method stays valid.
Paths below were read on `origin/main` at `a3d4fef`.

## Goal Capsule

- **Objective:** A controller may declare its collection model at class level. Preflight reads that declaration and does not call `new`. Controllers that only define the instance method keep working.
- **Authority hierarchy:** this plan, then issue #142, then the pairing rule in `lib/current_scope/guard.rb` lines 49 to 53, then `AGENTS.md`.
- **Execution profile:** One macro, a preflight read path, a boot warning when both forms disagree, and guide text. The macro is not required.
- **Stop conditions:** Do not remove the instance method. Do not drop the member-action caveat. Do not make preflight raise when host code in `new` raises. Do not change resolver order.
- **Tail ownership:** Issue #140 does not need this macro. Leave that refactor alone.

---

## Product Contract

### Summary

`SodPreflight#declared_model_for` (`lib/current_scope/sod_preflight.rb` line 294) calls `klass.new` and then `current_scope_model` so it can see the same method the request uses.
That runs host code at boot.
A class-level declaration can answer without `new` when the model does not depend on the action.

### Problem Frame

Some collection controllers return a constant model.
Instantiating them at boot can touch `params` and then gets rescued as "could not inspect", which hides a controller that is fine.
Other controllers branch on `action_name` inside the instance method. Those must keep using the instance method, and preflight must still say it may not know the member-action model.

### Requirements

- R1. `current_scope_model` is available as a class macro that takes the model class. Subclasses inherit it until they override it.
- R2. The macro also defines the instance method `current_scope_model` so the request gate keeps calling one method.
- R3. When the class-level value is set, `declared_model_for` uses it and does not call `new`.
- R4. When only the instance method exists, `declared_model_for` still calls `new`, as it does today, and still rescues host errors into the skipped list.
- R5. The macro is optional. A controller that does not declare a model is unchanged.
- R6. If a class has both a class-level value and an instance method that is not the method the macro defined, preflight appends that controller to a new `split_declarations` list. It does not put the warning in `skipped`. `degraded?` stays false. The static scan still returns the class value. The request gate keeps calling the instance method. The report's SoD section prints the list, and `Rails.logger.warn` names the controller once per scan.
- R7. The member-action limit stays: a collection declaration is not the member type. The warning text for that limit stays available to preflight.
- R8. `current_scope_model` without `current_scope_record` stays inert, for both the class form and the instance form. The Guard comment names the class form and the pairing rule.

### Acceptance Examples

- AE1. Macro only.
  - **Covers:** R1, R2, R3
  - **Given:** a controller class calls the macro with `Report` and `new` is stubbed to raise.
  - **When:** preflight asks for the model.
  - **Then:** the answer is `Report` and `new` was not called.
- AE2. Instance method only.
  - **Covers:** R4, R5
  - **Given:** a controller defines `current_scope_model` as an instance method.
  - **When:** preflight asks.
  - **Then:** it still instantiates, and a raise from `new` is skipped rather than fatal.
- AE3. Both, and the instance method was written by hand.
  - **Covers:** R6
  - **Given:** the macro set `Report` and a later instance method returns `Invoice`.
  - **When:** preflight runs.
  - **Then:** the controller is on `split_declarations`, `degraded?` is false, the static scan returns `Report`, and the request path uses `Invoice`.

### Scope Boundaries

- Do not require every controller to use the macro.
- Do not try to evaluate `action_name` at boot.
- Do not change `collection_type?` or the record-less branch.

### Sources

- `lib/current_scope/sod_preflight.rb` `declared_model_for` at line 294.
- `lib/current_scope/guard.rb` lines 32 to 54.
- `lib/current_scope/parent_chain.rb` for the class-macro shape already used by `current_scope_parent`.
- `test/sod_preflight_test.rb`.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. Store the macro value in a class attribute so subclasses inherit it. Define the instance method with `define_method` so the request gate's `send(:current_scope_model)` keeps working.
- KTD-2. Preflight reads the class attribute first. It calls `new` only when the attribute is unset. It does not call the instance method when the attribute is set.
- KTD-3. Detect a hand-written instance method by owner and method identity, not by source text. Warn when that method is not the one the macro installed. Do not silently prefer one side inside the request.
- KTD-4. The pairing rule stays a comment and a guide sentence. This plan does not make a missing `current_scope_record` a boot error. The gate already ignores the model in that case (`guard.rb` lines 49 to 53).

### Sequencing

- U1 adds the macro and the instance method it defines.
- U2 teaches preflight to prefer the class attribute and to warn on a split brain.
- U3 updates the Guard comment and the guide.

### Risks

- Two orders exist. Macro, then a later `def`: the request uses the `def`, and preflight warns. `def`, then the macro: the macro replaces the `def` and does not warn, because the instance method is then the macro's method. The guide tells the host to call the macro only, or to write the `def` after the macro if they need `action_name`. Calling the macro after a hand-written `def` drops that branch with no warning.
- Calling `new` to compare the instance result with the class value would bring back the boot side effect this issue removes. R6 compares method identity, not return values.

---

## Implementation Units

### U1. Add the macro

- **Goal:** A controller class can declare a model once, and instances answer the same model.
- **Requirements:** R1, R2, R5
- **Dependencies:** none
- **Files:**
  - the controller concern or `lib/current_scope` hook site that already adds controller class methods
  - a model-declaration test
- **Approach:** Add the macro next to the existing controller DSL. Set the class attribute and define the instance method. Leave controllers that do not call it untouched.
- **Patterns to follow:** `current_scope_parent` as a class macro that is not an instance method. This one is different on purpose: it must also define the instance method, because the gate calls the instance method. Say that in a comment.
- **Test scenarios:** A subclass inherits the model until it calls the macro again. An instance returns the declared class. A controller that never calls the macro has no class attribute set.
- **Verification:** Existing gate tests pass without calling the macro.

### U2. Preflight prefers the class value

- **Goal:** Preflight does not instantiate when the macro is set, and warns when a hand-written instance method also exists.
- **Requirements:** R3, R4, R6, R7
- **Dependencies:** U1
- **Files:**
  - `lib/current_scope/sod_preflight.rb`
  - `lib/current_scope/engine.rb` (the boot comment that says `new` is the only way to ask)
  - `lib/tasks/current_scope_tasks.rake` (both SoD report sections)
  - `test/sod_preflight_test.rb`
- **Approach:** In `declared_model_for`, return the class attribute when it is set, without `new`. Keep the current `new` plus rescue path for the instance-only case. When both exist and the instance method is not the macro's method, append the controller inside that cached call, so one controller with two SoD actions is named once. Do not put that warning in `skipped`. `degraded?` must stay false for a finished class read. Add one method that returns the split text, or nil when the list is empty. Call it at the start of `warn!`, before the empty-rows return. Call it from both report SoD sections. Do not log inside `scan` or inside `declared_model_for`. `scan` stays pure. Still return the class value for the static scan. Keep the member-action caveat text. Rewrite the `declared_model_for` comment and the engine boot comment. The class value is read on the class. `new` runs only when that value is unset.
- **Patterns to follow:** The rescue comment at lines 311 to 322. Do not let the new branch raise.
- **Test scenarios:** AE1, AE2, and AE3. AE3 asserts `split_declarations`, `degraded?` false, and that the scan used the class value. The quiet shape still warns: the model already defines `current_scope_initiator`, rows are empty, `degraded?` is false, `blind?` is false, and `warn!` names the controller. Both report SoD sections print the same list. A `collection_type?` rejection still returns nil. A host error on the instance-only path still lands in `skipped` and `degraded?` stays true. A string in `skipped` is not how the split is reported.
- **Verification:** AE1 proves `new` is not called. The degraded path for instance-only controllers still behaves as `test/sod_preflight_test.rb` describes today.

### U3. Document both forms

- **Goal:** The Guard comment and the guide name the class form, the instance form, and the pairing rule.
- **Requirements:** R8
- **Dependencies:** U1
- **Files:**
  - `lib/current_scope/guard.rb` lines 32 to 54
  - `docs/guides/checking-permissions.md` (the pairing example around lines 68 to 76)
- **Approach:** Add the class-form example beside the instance example. State both orders from the risk note. State that declaring both by hand warns only when the instance method is not the macro's method. State that the model hook without `current_scope_record` is inert.
- **Patterns to follow:** The existing comment's tone and the pairing paragraph at lines 49 to 53.
- **Test scenarios:** No behavior test. A docs assertion is optional and only if the suite already pins this comment.
- **Verification:** A reader of the comment can see both forms and the inert pairing without reading the issue.

---

## Verification Contract

| Check | Command | Proves |
|---|---|---|
| Preflight and gate | `bin/rails test test/sod_preflight_test.rb` plus the controller hook test added in U1 | R1 to R7 |
| Lint | `bin/rubocop` | Style |

One test process per checkout.

## Definition of Done

- Preflight does not call `new` when the macro is set.
- Instance-method controllers still instantiate and still degrade on host errors.
- A split declaration is listed on `split_declarations`, `degraded?` stays false, the static scan still uses the class value, and request-time lookup still uses the instance method.
- The macro is not required.
- The Guard comment mentions the class form and the pairing rule.
- Abandoned experiments are not left in the diff.
