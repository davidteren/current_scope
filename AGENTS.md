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
| `docs/internal/READINESS-AUDIT.md` | historical audit — its "DO NOT regress" invariants still bind |
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

## Review gate — before opening a PR (mandatory — never skip)

**Do not run `gh pr create` (or any skill that opens a new PR) until this
gate has completed on the exact commit that will be the PR head.**

On that commit, in order:

1. `/ce-code-review` — fix findings (may commit)
2. `/ie-review` — fix findings (may commit)
3. `/cubic-loop` (**local** mode) — fix findings until clean / residual P3 only
   (`/run-review` is a lighter one-shot cubic pass; it is **not** a substitute
   for step 3 of this gate)
4. **Local CI green** — run the suite and lint the way CI does before any push
   or PR create (unit/integration as CI does; `bin/rubocop` clean; system
   tests when the change touches UI or when CI would run them). Never open a
   PR on a red suite.

Prefer skill **`/dt-ship-pre-pr-gate`** for steps 1 to 3; still run step 4
yourself if the skill does not.

**Stale-gate rule:** if anything is committed after the gate finishes,
the gate is void — re-run steps 1 to 4 on the new `HEAD` before create. An
earlier pass on an older SHA does **not** count.

**Waive only if the user explicitly waives it in chat for that PR** —
never self-waive for "small" or "docs-only" diffs.

Milestone / release gate (before any version bump or RubyGems tag):
`dte-deep-reviewer` + `dte-test-auditor` + `/security-review`.

## After opening a PR (mandatory — never skip)

Never merge, never suggest merge, and never treat the PR as ready until all
of the following are done on the **current** head:

1. **Wait** for remote CI and agentic reviewers to settle on the head SHA
   (cubic, qodo, Devin, and any other required checks). Do not declare ready
   while a review bot is still pending.
2. **Re-review the open PR** with the same three lenses (PR-aware where the
   skill supports it): `/ce-code-review`, `/ie-review`, `/cubic-loop` in
   **PR mode** (or local cubic on that branch if PR mode cannot run). Fix
   real findings; commit + push; re-run after material HEAD moves.
3. **Address every review comment / thread** (human or bot):
   - Fetch unresolved threads (GraphQL `reviewThreads` preferred)
   - Fix when warranted; commit + push; confirm the SHA is on the remote
     before replying
   - **Reply inline on every thread** with agent prefix first
     (`**Grok:**`, `**Claude:**`, … — `gh` posts under David's account)
   - Fixed: what changed + commit SHA
   - Not fixed: rationale (false positive / intended / already covered —
     and where)
   - **Deferred:** must name the **GitHub issue** that tracks the deferral
     (number + link or full title). "Later" alone is not allowed
   - Never resolve a thread silently (reply first, then resolve if tooling
     does). See PR #64/#71.
4. **CI green** on the head SHA after the last push (lint, test, other
   required workflows). Skills: `check-pr-comments`, `dt-ship-pr-readiness`.
5. **Never merge** unless the human asks — report readiness only.

Roll up review counts in chat, not as a separate PR-level summary comment.

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
