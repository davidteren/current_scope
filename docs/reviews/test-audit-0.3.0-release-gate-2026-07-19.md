# dte-test-auditor — 0.3.0 release gate (record-less collection gate, PRs #88/#89)

_2026-07-19 · Tools used: rails-test-smell-checker (clean, 53 files, 0 smells),
manual behavior→test coverage mapping, hand-mutation probes (14, isolated
worktree — repo house style; the mutant gem is not set up) · Tools unavailable:
SimpleCov (not in bundle — no line-coverage number; audit is
mapping+quality+mutation), mutant gem (recommend wiring both if the suite
keeps growing)_

## Verdict

**STRONG (A-) — the 0.3.0 suite earns its trust; no release blocker.**
Baseline: full suite 554 runs / 1692 assertions green on `main`; system tests
21 runs green (1 intentional skip: `ScreenshotsTest`, gated behind
`CAPTURE_SCREENSHOTS=1`). Mutation: 11/14 probes killed; 2 of the 3 survivors
are equivalent mutants, 1 is a real (small) gap. Every load-bearing behavior
of the #50/#65 change maps to a covering test at both resolver-unit and
real-request level.

## Coverage

All 19 mapped behaviors COVERED, including: both read-arm allows (explicit
tick + scoped full_access), empty-list / destroyed-record / default_scope
denies, opt-out via `[]`, non-read explicit-tick allow + full_access deny,
type-mismatch deny, STI base_class normalization, nil-type deny with
`:model_undeclared` label, non-AR/abstract deny in both hook and class forms,
SoD refusal on the record-less branch, class-form binding ignoring `model:`,
ambient cross-controller isolation (KTD-6), NO_RECORD inert-model (R9), the
config writer's raise/warn/freeze/normalize, both new nudges
(fired + suppressed), and report-mode × `:model_undeclared`. Notable
strengths: resolver purity pinned with `assert_no_difference`; the gate/list
biconditional pinned as a matrix in `test/scope_for_test.rb:113`.

Only unit-level (minor): empty-list / destroyed / scoped-out denies have no
integration GET driving a real 403 through the filter chain
(`collection_scope_gate_test.rb:498/:514`).

## Findings

1. 🟠 **No negative pin on non-canonical mutating names** —
   `test/configuration_test.rb:197`. `collection_read_actions = %w[destroy_all]`
   is silently accepted with no warning (`MUTATING_ACTION_NAMES` is only
   create/update/destroy) and no test characterizes that ceiling — yet
   `configuration.rb:156` names `destroy_all` as the escalation example.
   **Add:** a test asserting `%w[destroy_all]` is (i) accepted and stored and
   (ii) emits NO warning, documenting the partial-blocklist limitation.
   _(Same gap flagged independently by the ce and ie review lenses.)_
2. 🟠 **Mutation survivor M10: the writer's `.freeze` is untested** — deleting
   `.freeze` in `collection_read_actions=` passes the whole suite. The freeze
   is load-bearing per its own comment (blocks `<< :export` in-place mutation
   from dodging normalization, the `#`-key raise, and the mutating warning),
   but only the default's freeze is incidentally exercised. **Add**
   (`test/configuration_test.rb`): assign `%w[index export]`, then
   `assert_raises(FrozenError) { config.collection_read_actions << "create" }`.
3. 🟡 **Suppressed side of the mutating warning unpinned** — no test asserts a
   clean list (`%w[index export]`) emits no warning. One `capture_rails_log`
   assertion closes it.
4. 🟡 **Integration empty-list deny** — one GET-after-destroy →
   `:forbidden` on a listed-read controller would prove the deny through the
   full filter chain (currently unit-only).
5. 🟡 **SoD-vs-record-less ordering is guard-protected, not order-pinned**
   (mutation survivor M14, equivalent today). The invariant is held by
   `return false if sod_action?(permission)` inside the record-less branch
   (probe M8 — killed by AE6), not by `decide`'s ordering; reordering alone is
   unobservable, but M8+M14 together would be fail-open. Optional pin: extend
   the `test/resolver_test.rb` reason-trio test to assert the break-glass path
   returns `[true, :sod_bypassed]` (never plain `nil`), which any
   grant-branch-first reorder would redden.
6. ℹ️ **Equivalent mutant M3** — `return false if type.nil?` in
   `record_less_scoped_grant?` is redundant with the AR-shape guard on the
   next line (`nil.is_a?(Class)` is false). Readability choice, no test
   possible or needed.
7. ℹ️ **Prose-pinned diagnostics are deliberate** — the honesty tests in
   `dev_diagnostics_test.rb:79/:472` pin exact wording; judged
   behavior-adjacent (the wording IS the diagnostic contract). Keep, but
   expect a copy-edit to redden them; narrow to stable marker phrases if that
   churns.

## Mutation probe table (11 killed / 3 survived)

| Probe | Mutation | Result |
|---|---|---|
| M1 | read arm → `true` | KILLED (7 tests, 3 files, incl. request-level) |
| M2 | read arm → type-bound boolean over `roles_granting` (withdrawn R4 shape) | KILLED |
| M3 | delete nil-type guard | SURVIVED — equivalent mutant |
| M4 | delete AR-shape/abstract guard | KILLED |
| M5 | non-read arm → `roles_granting` | KILLED |
| M6 | drop `resource_type:` filter | KILLED |
| M7 | `collection_read_action?` → always true | KILLED (8 tests) |
| M8 | delete SoD refusal in record-less branch | KILLED (AE6) |
| M9 | `:model_undeclared` labeler → always true | KILLED |
| M10 | drop `.freeze` in writer | **SURVIVED — real gap (finding 2)** |
| M11 | delete keyed-member raise | KILLED |
| M12 | stash ambient model even for NO_RECORD | KILLED |
| M13 | drop controller-path guard in `ambient_collection_model` | KILLED |
| M14 | record-less branch before SoD veto | SURVIVED — equivalent under M8's guard (finding 5) |

No over-mocking (the one collaborator stub is a legitimate call-count seam,
`ensure`-removed); global config `ensure`-restored throughout; assertions
carry messages — meets the AGENTS.md bar. Hand test additions (findings 1–4)
to `minitest-coder` / a follow-up PR; none blocks the tag.
