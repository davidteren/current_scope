# AGENTS.md

Workflow contract for agents working in this repo. Single source of truth —
`CLAUDE.md` just points here.

## What this is

**CurrentScope** — a mountable Rails engine for authorization: permissions
derived from `controller#action` routes, roles as editable data, scoped roles,
an SoD (four-eyes) veto, impersonation, and an audit ledger. v0.2.0 is on
RubyGems; not production-ready.

| Where | What |
|---|---|
| `STATUS.md` | what's done, per-session log, verification brief |
| `docs/ROADMAP.md` | gaps + proposals (what's next) |
| `resources/DESIGN.md` | design concept; §3.7 resolver order, §9 open questions |
| `docs/READINESS-AUDIT.md` | historical audit — its "DO NOT regress" invariants still bind |
| `docs/plans/`, GitHub issues | current work |

**Drift rule:** if code and docs drift, update the docs in the same commit.

## Hard rules

1. **Fail-closed is the product.** Any change to `lib/current_scope/resolver.rb`
   keeps default-deny and the decision order SoD veto → full_access → org-wide
   role → scoped role → record-less target → deny (DESIGN.md §3.7). SoD stays
   non-configurable-in-UI and overrides full_access — that's its whole point.
2. **Vanilla Rails first.** No Devise, no Pundit, no dry-effects; a new gem only
   when Rails genuinely can't do it (owner's explicit constraint).
3. **Don't regress the READINESS-AUDIT invariants** ("Verified holding — DO NOT
   regress" section) or the prod impersonation boot-raise guardrail.
4. **UI changes get driven in a real browser before merge.** Unit tests render
   views without layout and miss visual regressions — see Testing below.

## Git workflow

- **PRs always**: branch → PR → main. No direct pushes to main.
- Commits imperative and plain; reference issues (`(#62)`, `Closes #62`).
- Issue/PR descriptions open with a plain-language **What / Why / How** a
  non-technical reader could follow; technical detail below that block.
- Never push a failing suite.

## Review gate — before opening a PR

1. `/ce-code-review` — fix findings
2. `/ie-review` — fix findings
3. `/run-review` (cubic) — fix findings

Milestone / release gate (before any version bump or RubyGems tag):
`dte-deep-reviewer` + `dte-test-auditor` + `/security-review`.

**After opening a PR (mandatory — never skip):**

1. **Wait** for PR review agents (cubic, qodo, Devin, etc.) to finish.
2. **Address every comment** — valid ones: fix in code/docs; invalid ones:
   still reply (do not ignore).
3. **Reply inline on every thread** before resolving — agents use those
   replies to self-learn. Fixed: agreement + what changed + fix commit SHA.
   Not fixed: rationale (false positive / intended / already covered — and
   where). Never resolve silently. Confirm the fix commit is on the remote
   before resolving (see PR #64/#71).
4. **CI green** — lint, test, and other required workflows must pass before
   declaring ready (skills: `check-pr-comments`, `dt-address-PR-for-readiness`).
5. **Never merge** unless the human asks — report readiness only.

## Tool & skill playbook

**Discovery order:** `codebase-retrieval` (Augment) first for "how/where does X
work"; Grep/Glob for exhaustive exact matches; LSP or RubyMine MCP
(`get_symbol_info`, `get_rails_routes`) for structural/runtime facts. Never
Bash `grep`/`find`.

**Runtime verification:** Chrome DevTools MCP drives the running app; `/verify`
for end-to-end confirmation of a change.

**Building:** Rails work → `majestic-rails` skills (`hotwire-coder`,
`viewcomponent-coder`, `minitest-coder`, `ruby-coder`); UI/design →
`/ui-design` + `frontend-design`; architecture questions → `layered-rails`
reviewer/planner.

## Testing

- Minitest. Engine test DB from repo root:
  `RAILS_ENV=test bundle exec rake db:create db:migrate` (the engine's
  `bin/rails` runs ONE command per invocation — `db:test:prepare test` in one
  call fails; split them, as CI does).
- System tests (Capybara + cuprite, headless): `bin/rails test:system` — also
  CI-enforced. Regenerate README screenshots with
  `CAPTURE_SCREENSHOTS=1 RAILS_ENV=test bin/rails test test/system/screenshots_test.rb`.
- **Stable DOM ids mandatory** in engine views: semantic snake_case `id` on
  every interactive/assertable element (the repo's established shape —
  `perm_<controller>_<action>`, `cs_ungated_<controller>`; controller paths go
  through `parameterize(separator: '_')`). Repeated elements are identified by
  their per-instance ids plus a stable class for the kind — no `data-testid`
  (never used in this codebase). System-test selectors use ids/classes chosen
  for tests only — never CSS structure or text. Renaming an id is a breaking
  change: update specs in the same commit.
- Non-trivial logic ships with its test in the same commit.
- Integration-test gotcha: after requesting the mounted engine, SCRIPT_NAME
  sticks in the session — use literal paths (`"/session"`) for host routes.

## Conventions

- RuboCop omakase on the engine: `bin/rubocop` clean before commit.
- Showcase app is the sibling repo `current_scope_showcase` (:3006), consumes
  the published gem. When running the engine as a `path:` gem in dev, `lib/`
  changes need a server restart (`kill -USR2 <puma_pid>`) — `app/` hot-reloads,
  `lib/` does not; a stale `lib/` PORO can 500 on correct code.
- `current_scope_record` host hooks run before host `before_action`s and for
  every GATED action (an action that skips `current_scope_check!` never runs
  the hook) — hooks must lazy-load and nil-guard.
- SoD opt-out is config, not a fork: `config.sod_actions = []` makes the veto
  a no-op.
