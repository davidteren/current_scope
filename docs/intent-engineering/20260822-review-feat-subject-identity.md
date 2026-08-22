# Intent Engineering review — PR #169 (feat/subject-identity)

- **Run:** 20260822-feat-subject-identity
- **Head:** 0e61dac (reviewed) → fixes applied on top
- **Base:** main
- **Scope:** local-aligned
- **Lenses:** predictability, convention, simplicity (config `on`); experience (rake-task CLI surface); architecture (Rails detected, structural change in `lib/`)
- **Config:** `.intense/` — plugin defaults; `severity_overrides {}`, `conventions.notes []`, `tools.architecture: enrich` (reek/flog absent, heuristic-only), `patterns.yaml` all lists empty, `unknown_pattern.raise: true` @ P3
- **Verdict:** Ready with fixes (applied)

## Applied

| # | Finding | Principle | Lens | File |
|---|---------|-----------|------|------|
| 1 | `identity:check` printed "is unique" for a host object that never implements `unique?` | wysiwyg | predictability (+security residual) | `lib/tasks/current_scope_tasks.rake` |
| 2 | `print_plan` said "Would grant" on the `WRITE=1` path, one line before "Granted" | ux-design | experience, predictability | `lib/current_scope/identity_setup.rb` |
| 3 | Dry-run hid that `WRITE=1` creates the Role row and seeds Owner/Member | wysiwyg | predictability | `lib/current_scope/identity_setup.rb` |
| 4 | `ai-agents.md` hardcoded `IDENTITY=email` for all three identity shapes, contradicting the generator | information-architecture | experience | `docs/site/ai-agents.md` |
| 5 | `production?` belonged on the `CurrentScope` facade, as `mysql?` is | convention-over-configuration | convention | `lib/current_scope.rb` |
| 6 | `placeholder_factory` wrapped one call in a lambda | kiss | simplicity | `lib/current_scope/identity_setup.rb` |
| 7 | `ColumnResolver#stringify` nil branch unreachable after the blank guard | kiss | simplicity | `lib/current_scope/subject_identity.rb` |
| 8 | Sibling resolvers disagreed on a one-element Array key | api-design | predictability | `lib/current_scope/subject_identity.rb` |
| 9 | `identify_subject` enforced a class invariant `resolve_subject` did not | api-design | predictability | `lib/current_scope.rb` |
| 10 | Template `unique?` argued in prose that its own default was too costly | occams-razor | simplicity | generator template |

## Open — reported, not applied

| Finding | Why not applied | Lens |
|---------|-----------------|------|
| Replace the `unique?` / `colliding_keys` pair with one `collision_report` question | The real fix for the duplicate-path double scan. Same root cause the ce-code-review performance lens found at anchor 100. Needs a protocol change across three call sites; the obvious shortcut breaks `HostResolver`. | simplicity, performance |
| `IdentitySetup` exposes 4 public methods vs `max_public_methods: 1` | Structural refactor (extract an `IdentityOverride` collaborator). | architecture |
| `*Resolver` naming collides with the glossary-level `CurrentScope::Resolver` | Branch-wide rename. | convention |
| Narrow `IDENTITY=` to `setup` only, dropping it from `check` | **Tension:** the plan lists it as a supported ENV and the adoption flow needs it before the initializer exists. | simplicity |
| Parse composite `SUBJECT` from the value (leading `[`) rather than the config shape | **Tension:** strict-by-shape is safer for a task that writes grants. | predictability |
| Role-replacement warning goes to stderr while the plan goes to stdout | Below the confidence gate. | experience |
| Add a `strategy` entry to `.intense/patterns.yaml` `allowed` | Editing the project's own policy file is the owner's call. | architecture |
| `unique_index?` swallows every `StandardError` with no log | Observation; the fallback direction is safe. | predictability |

## Coverage

All five lenses returned clean JSON; none failed or was skipped. Suite green at 896 unit / 28 system runs, RuboCop clean, on the applied state.
