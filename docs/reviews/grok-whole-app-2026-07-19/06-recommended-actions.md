# Recommended actions — ordered

_2026-07-19 · Synthesized from all lenses. Prefer small PRs; each row is independently shippable._

## P0 — before 0.3.0 tag (security / silent fraud-control)

| # | Action | Files | Why |
|---|---|---|---|
| 1 | Normalizing writer for `sod_actions` (+ freeze + tests for symbols) | `configuration.rb`, `configuration_test.rb`, `resolver_test.rb` | Symbol list silently disables SoD |
| 2 | Refuse demoting last full_access role on update | `roles_controller.rb`, `management_ui_test.rb` | Console lockout |
| 3 | Refuse clearing last full_access org holder | `role_assignments_controller.rb`, integration test | Console lockout |
| 4 | Ensure main has Hash/non-String raise on `collection_read_actions=` | `configuration.rb` (pre-tag may already have it) | Silent un-fix of #65 |
| 5 | Expand mutating warn list with `destroy_all` / `update_all` | `configuration.rb` | Docs-named escalation |

## P1 — soon after tag (still high ROI)

| # | Action | Why |
|---|---|---|
| 6 | Role delete confirm with holder counts + danger button | Operators wipe grants blindly |
| 7 | Picker `label_tag` / `for=` associations | a11y |
| 8 | Subjects row aria-labels for Set controls | a11y |
| 9 | Empty states for Roles / Events / Subjects | first-run DX |
| 10 | `private :ambient_collection_model` | accidental public API |
| 11 | Reword Guard purity comment | doc accuracy |
| 12 | Integration empty-list deny GET | request-path pin |
| 13 | Non-admin mutation POST tests | self-escalation regression |
| 14 | Org-role uniqueness model test | schema-only today |

## P2 — product / docs / deferred architecture

| # | Action | Why |
|---|---|---|
| 15 | Production checklist: `audit: :strict`, actor_method, tripwire include, leave report mode | A2/A4/A6 residuals |
| 16 | Optional dual-hook macro `current_scope_collection` | adoption cost |
| 17 | Page titles via `content_for` | multi-tab AT |
| 18 | Access-denied return link | UX dead end |
| 19 | Cascade `aria-busy` | loading state |
| 20 | Stable DOM ids on remaining interactive controls | AGENTS.md |
| 21 | Guard diagnostics extract | only when next nudge lands |
| 22 | Scoped-grant request memo | only if profiled N+1 |
| 23 | SimpleCov (+ optional mutant) in CI | coverage number |

## Explicit non-actions (do not “fix open”)

| Item | Rationale |
|---|---|
| A5 org+nil SoD skip | Documented residual; scoped + report blind spots closed |
| Report mode hard-403 `:model_undeclared` | Deliberate pin — keep |
| Trusted `current_scope_model` | #65 trade — document, review like record hook |
| Auto-include GatingTripwire | Would surprise hosts; keep opt-in |
| Extract services / Pundit-like policies | Vanilla Rails first; YAGNI |

## Suggested PR stacking

1. **PR A — config writers:** #1 + #4 + #5 (one theme: silent config)  
2. **PR B — last full-access completeness:** #2 + #3  
3. **PR C — test pins:** #12 + #13 + #14  
4. **PR D — UI safety/a11y:** #6 + #7 + #8 + #9  
5. **PR E — small polish:** #10 + #11  

Hand off to `dte-arc-plan` if you want validated plan docs per PR.
