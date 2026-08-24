# Runbook: execute the #116 real-host bake findings

**Type:** runbook (execution order across two repos). Not a plan for one issue.
**Owns:** the four findings the #116 bake produced, plus the steps no plan owns.
**Date:** 2026-08-24 (revised after the second validation pass, which added issue #758)

Issue **#116** is "Solid v1: docs-and-polish sprint to drop the not-production-ready
banner" on `davidteren/current_scope`. Its last open Wave 3 item is: one real host
runs report mode, reads `rails current_scope:report`, then flips
`config.enforcement` to `:enforce`.

The bake ran against `davidteren/miela_app` (PostgreSQL, upgraded from current_scope
0.4.0 to 0.5.1). It produced **four** findings, now filed as issues **#190** and **#191**
(both `current_scope`), and **#757** and **#758** (both `miela_app`).

| Issue | Repo | Kind | What it is |
|---|---|---|---|
| [#190](https://github.com/davidteren/current_scope/issues/190) | `current_scope` | bug | The report counts denials on **deleted** records as outstanding for ever, so #116's exit condition is unreachable. |
| [#191](https://github.com/davidteren/current_scope/issues/191) | `current_scope` | docs | `UPGRADING.md` 0.4 to 0.5 omits `db:test:prepare`, and documents the string-id change as a note rather than a silent breakage. |
| [#757](https://github.com/davidteren/miela_app/issues/757) | `miela_app` | bug | current_scope 0.5 string ids break two host comparison sites. One deletes every scoped grant; one blanks the admin roles column. |
| [#758](https://github.com/davidteren/miela_app/issues/758) | `miela_app` | bug | The CurrentScope gate runs **before** authentication, so flipping to `:enforce` turns every signed-out visit into a 403 instead of a sign-in redirect. **This is the flip blocker.** |

#758 was found by a completeness critic after the first three plans were written. It is
the reason this runbook has four stages of work and not three.

---

## Three-line handoff

- **What this is:** the step-by-step order for shipping the four bake fixes and then
  closing the #116 real-host bake.
- **What we finished:** all four plans are written and re-validated. The #757 and #190
  plans came back **ready** with nothing left to decide; the #191 and #758 plans each
  have a short must-fix list, written out below.
- **What you do next:** start Stage B and branch `fix/757-current-scope-string-ids` in
  `miela_app`, whose plan needs no more edits before you write code.

---

## 1. Current state of both repos (read this first)

### `miela_app` (`/Users/davidteren/Projects/VA/miela_app`)

- On branch **`chore/current-scope-bake-116`**, with **no upstream** (never pushed).
- Four **uncommitted** gem-upgrade changes:
  - `Gemfile` (modified). Line 54 pins
    `gem "current_scope", github: "davidteren/current_scope", ref: "8036b33b865d2cd6a5bba52b60c8e37ab10a8760"`
  - `Gemfile.lock` (modified)
  - `db/schema.rb` (modified)
  - `db/migrate/20260824035737_widen_current_scope_polymorphic_ids.current_scope.rb` (new, untracked)
- Two untracked plan files:
  - `docs/plans/2026-08-24-001-fix-current-scope-string-ids-plan.md` (issue #757)
  - `docs/plans/2026-08-24-002-fix-authentication-before-current-scope-gate-plan.md`
    (issue #758)
  - Each plan file is committed on **its own** issue branch, with that issue's PR.
- The default branch and `STAGING_BRANCH` is **`release/phase-6`**. Feature and fix
  branches cut from it and PR back into it. Confirm before you branch:
  `gh variable list` and `gh repo view --json defaultBranchRef`.
- **Only the local development database has the widened `varchar(64)` grant columns.**
  Staging and production still run current_scope 0.4.0 against `bigint`. The data-loss
  exposure is therefore local-only until this PR merges.

### `current_scope` (`/Users/davidteren/Projects/DT/current_scope`)

- On branch `docs/166-crash-holding-the-door`, working tree otherwise clean.
- Two untracked plan files sitting on that branch's tree:
  - `docs/plans/2026-08-24-001-fix-report-moot-vs-unknown-plan.md` (issue #190)
  - `docs/plans/2026-08-24-001-docs-upgrading-04-05-honesty-plan.md` (issue #191)
  - Each plan file must be committed on **its own** issue branch, not on `main` and not
    together.
- `main` is the base for both new branches. PRs always, no direct pushes to `main`.

---

## 2. Order of the four PRs, and why

Do them in this order, one at a time.

| # | Repo | Issue | Branch | Base | Why this position |
|---|---|---|---|---|---|
| 1 | `miela_app` | #757 | `fix/757-current-scope-string-ids` | `release/phase-6` | Wall-clock urgency, and it carries the gem bump. Until it lands, one `bin/rails current_scope:migrate_roles` on the upgraded local development database classifies all 200 scoped grants as stale and deletes them. It also puts current_scope 0.5.1, the widened columns and the string-id fix into the base that every later `miela_app` branch cuts from. |
| 2 | `miela_app` | #758 | `fix/758-authentication-before-current-scope-gate` | `release/phase-6`, after #757 merges | The flip blocker. It is the only fix here that **must** exist before `config.enforcement` moves off `:report`. It goes second because it wants #757's gem bump already in its base, not because it depends on #757's code. It blocks nothing else, so it does not have to precede #190 or #191. |
| 3 | `current_scope` | #190 | `fix/190-report-moot-vs-unknown` | `main` | It blocks the re-bake in Stage F. The host cannot read a truthful outstanding count until the moot classification ships, and the second gem-pin bump has nothing to point at until #190 is on `main`. |
| 4 | `current_scope` | #191 | `docs/191-upgrading-04-05-honesty` | `main`, rebased after #190 merges | Documentation only, no engine code, and nothing waits on it. It deliberately loses the `CHANGELOG.md` race to #190. |

### The four ordering constraints, stated once

1. **#757 first.** It is the only finding with live data at risk, and it carries the gem
   upgrade the other `miela_app` work builds on.
2. **#190 before #191.** Both add a bullet to the same `CHANGELOG.md` `[Unreleased]` →
   `### Fixed` list (starts around line 73). Whichever lands second has to rebase that one
   hunk. Ship #190 first, then rebase the #191 branch on `main` **before** its pre-PR gate
   runs, so the gate runs on the head that will actually be merged.
3. **#190 before the second gem-pin bump.** After #757 merges, `miela_app`'s `Gemfile:54`
   still pins ref `8036b33`, a gem build **without** the moot fix, so the host would still
   read 350 permanently outstanding denials. Stage F1 bumps that pin a second time and
   re-reads the report. It cannot run until #190 is on `current_scope` `main`.
4. **#758 before the `:enforce` flip.** The flip cannot happen while a signed-out visit
   would return 403 instead of the sign-in page. Nothing else waits on #758, and #758
   waits on nothing except a clean base.

**Functional independence.** #190 and #191 are independent of each other and of both
`miela_app` fixes. #757 and #758 touch different files in `miela_app`: #757 edits
`db/seeds/current_scope_roles.rb` and the admin users view, #758 edits
`app/controllers/application_controller.rb`, `app/controllers/concerns/authentication.rb`
and ten other controllers. There is no code conflict between them; the sequencing is about
base cleanliness and about doing one PR at a time.

**Cross-issue references, both now satisfied.** Two references were missing at the first
validation pass and are present in the plans now. Keep them true while you edit:

- The #191 plan bounds its "your queries are safe" claim to Active Record hash and record
  conditions, and names its evidence as one application's queries on PostgreSQL during
  this bake (plan requirement R5 and KTD5). The underlying sweep is the table in the
  `miela_app` #757 plan, rows 3, 4 and 7.
- The #757 plan's Deferred section names issue #191 by number and link, rather than
  saying "file this against `davidteren/current_scope`".

---

## 3. The per-PR runbook (apply to every one of the four)

Copy this sequence for each of the four PRs. Do not invent a second sequence.

### Step 0: Resolve the validator must-fix list

Work through the issue's must-fix checklist in Stage B, C, D or E below. Every box is a
**decision recorded in the plan file** before any code is written. Edit the plan file
itself; that edit is part of the PR. Two of the four stages (#757 in Stage B, #190 in
Stage D) came back **ready** on re-validation, so their lists are already closed and
Step 0 costs you nothing there.

### Step 1: Branch

```bash
# current_scope
cd /Users/davidteren/Projects/DT/current_scope
git checkout main && git pull
git checkout -b <branch-from-the-table-above>

# miela_app (base is the release branch, not main)
cd /Users/davidteren/Projects/VA/miela_app
gh repo view --json defaultBranchRef -q .defaultBranchRef.name   # expect release/phase-6
git checkout -b <branch> <that-branch-name>
```

One issue, one branch, one PR. Commits are imperative and reference the issue
(`(#190)` or `Closes #190`).

### Step 2: Implement the units in dependency order

Follow the plan file's U1, U2, U3 (and U4) order. Every new test arm is proved red
before the fix where the plan labels it change-detecting, and proved green against the
base where the plan labels it a regression pin.

### Step 3: The mandatory pre-PR review gate

Run on the **exact commit that will be the PR head**, in this order, fixing findings
between each:

- [ ] `/ce-code-review`, then fix findings, commit if needed
- [ ] `/ie-review`, then fix findings, commit if needed
- [ ] `/cubic-loop` in **local** mode, iterating until clean or residual P3 only
- [ ] **Local CI green**, run the way CI runs it (commands per repo, below)
- [ ] **Write the gate-record file.** `gh pr create` is blocked without it:

```bash
GATE_END_SHA=$(git rev-parse HEAD)
mkdir -p /tmp/dt-ship-pre-pr-gate
printf '%s\n' "$GATE_END_SHA" "branch=$(git branch --show-current)" \
  "when=$(date -u +%Y-%m-%dT%H:%M:%SZ)" "repo=$(git rev-parse --show-toplevel)" \
  > "/tmp/dt-ship-pre-pr-gate/$(basename "$(git rev-parse --show-toplevel)")-latest.txt"
```

`/dt-ship-pre-pr-gate` runs the three lenses and writes that file. It does not always
run local CI, so run Step 3's CI line yourself.

**Stale-gate rule.** If anything at all is committed after the gate finishes, the gate
is void. Re-run all of Step 3 on the new `HEAD`. An earlier pass on an older SHA does
not count. Never self-waive for "docs-only" or "small".

#### Local CI commands, `current_scope`

`rake test` runs nothing and exits 0. It is not the test command. Use `bin/rails test`.
The engine's `bin/rails` runs **one** command per invocation, so split them exactly as
CI does:

```bash
cd /Users/davidteren/Projects/DT/current_scope
bin/rails db:test:prepare
SIMPLECOV_COMMAND_NAME=unit   bin/rails test
SIMPLECOV_COMMAND_NAME=system bin/rails test:system
bin/rubocop
```

#### Local CI commands, `miela_app`

```bash
cd /Users/davidteren/Projects/VA/miela_app
bin/rails db:test:prepare
bin/rails test
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
```

### Step 4: Open the PR

```bash
git push -u origin <branch>
gh pr create --base <main | release/phase-6> --title "..." --body "..."
```

The body opens with a plain-language **What / Why / How** block a non-technical reader
could follow. Technical detail goes below that block.

### Step 5: After the PR is open

- [ ] **Wait** for remote CI and every agentic reviewer to settle on the head SHA:
      cubic, Devin, qodo, CodeRabbit, Copilot, and any other required check. Poll until
      they complete, or until a clear timeout with the last known status. Do not call
      the PR ready while a bot is still pending.
- [ ] **Re-run the three lenses PR-aware** on the open PR: `/ce-code-review`,
      `/ie-review`, `/cubic-loop` in **PR** mode (local cubic on that branch if PR mode
      cannot run).
- [ ] **Fix every real finding.** Commit and push on the PR branch. Confirm the SHA is
      on the remote before you reply anywhere.
- [ ] **Reply INLINE on every review thread**, human or bot, with the bold agent prefix
      first because `gh` posts under David's account:
  - Fixed: `**Claude:** ` plus what changed plus the commit SHA.
  - Not fixed: `**Claude:** ` plus why (false positive, intended, already covered and
    where).
  - Deferred: `**Claude:** ` plus the **GitHub issue number and link** that tracks it.
    "Later" alone is not allowed.
  - **Reply before you resolve.** Never resolve a thread silently.
- [ ] Do **not** post a separate PR-level summary comment. Roll the counts up in chat.
- [ ] Re-run the lenses again if a material fix moved `HEAD`.

### Step 6: Green, then stop

- [ ] CI green on the head SHA after the last push.
- [ ] Report readiness. **Then stop.** The human merges.
- [ ] Never merge, and never suggest merging, while any check or any thread is
      outstanding.

---

## Stage A: Before any code, in either repo

- [ ] Read `AGENTS.md` in the repo you are about to touch. It is the authority on the
      gate, testing policy, and the hard rules.
- [ ] Use `mcp__auggie__codebase-retrieval` first for any "where does X happen" question.
      Grep only when you need every occurrence of a known identifier.
- [ ] Keep the honest claim about #190 everywhere it is repeated. On the bake host the
      count goes **1029 to 679**, with **350** denials moving to the new moot line, so the
      fix makes zero **reachable**; it does not make the count reach zero. The #190 plan
      already says this in its Goal Capsule. Carry the same word into the PR body, into the
      comment on issue #190, and into the Stage F1 reading posted on #116.
- [ ] Check the four plans against each other before you start, not after. Two documents
      quote the same numbers (#190's plan and this runbook quote 1029, 679 and 350), and
      two quote the same blast radius (#757's "one operator-run task" and this runbook). If
      you change a number in one place, change it in all of them in the same commit.

---

## Stage B, PR 1: `miela_app` issue #757

**Issue #757:** "current_scope 0.5 string ids: re-seeding silently deletes every scoped
grant, and the admin users page shows no role."

**Plan:** `/Users/davidteren/Projects/VA/miela_app/docs/plans/2026-08-24-001-fix-current-scope-string-ids-plan.md`

### B1. Nothing to resolve: the plan came back ready

The re-validation verdict on
`/Users/davidteren/Projects/VA/miela_app/docs/plans/2026-08-24-001-fix-current-scope-string-ids-plan.md`
is **ready**, with **no** remaining must-fix items. The first-pass objections are answered
inside the plan now, and they are answered correctly. Do not re-open them. Two of the
answers are load-bearing for the rest of this runbook, so they are restated here:

- **The blast radius is one path, not three.** `sync_scoped!` is called only from
  `CurrentScopeRoleSeed.migrate!` (`db/seeds/current_scope_roles.rb:233-234`), and
  `migrate!` has exactly one non-test caller, `lib/tasks/current_scope.rake:17`, the task
  `bin/rails current_scope:migrate_roles`. `db/seeds.rb:69` and
  `app/controllers/test_helpers_controller.rb:325` call `seed!`, and `seed!` never calls
  `migrate!`; the dependency runs the other way, `migrate!` calls `seed!` at line 221. No
  deploy hook and no CI job reaches it: `bin/docker-entrypoint` runs
  `bin/rails db:prepare toggl:seed_windows`, and `.github/workflows/ci.yml:260` runs
  `bin/rails db:prepare db:seed`. **The exposure is one operator typing one command against
  one database.** Issue #757 has been corrected to match. If you find "three routine paths"
  in any older text, that text is stale and this paragraph is the correct version.
- **The task is `bin/rails current_scope:migrate_roles`.** There is no
  `current_scope:roles` task; that name fails with "Don't know how to build task".
  `DRY_RUN=1 bin/rails current_scope:migrate_roles` is the safe preview form, and it is
  what you run before the real one.
- **Only the local development database is exposed today.** The gem bump is uncommitted on
  a local branch, so staging and production still run current_scope 0.4.0 against `bigint`
  columns, and their comparisons are still correct.
- The browser check has its precondition and a named expected value, the view-versus-
  controller keying decision is recorded, the staging count check is in the Definition of
  Done, and the Deferred section names issue #191 by number and link.

### B2. Branch and land the uncommitted work

The four uncommitted gem-upgrade files belong in **this** PR. U3 says so, and it is
correct: neither half is right alone, and the regression tests only reproduce the bug
against the widened schema.

```bash
cd /Users/davidteren/Projects/VA/miela_app
git branch -m chore/current-scope-bake-116 fix/757-current-scope-string-ids
git log --oneline -1 release/phase-6   # confirm the branch is current with the base
```

The branch has no upstream, so the rename is free. If `release/phase-6` has moved,
rebase before the gate runs.

- [ ] `git add Gemfile Gemfile.lock db/schema.rb db/migrate/20260824035737_widen_current_scope_polymorphic_ids.current_scope.rb`
- [ ] `git add docs/plans/2026-08-24-001-fix-current-scope-string-ids-plan.md`
- [ ] Commit the gem upgrade and the plan as their own commit, then implement U1, U2, U3.

### B3. Implement

- [ ] **U1**: `CurrentScopeRoleSeed.sync_scoped!`: compare all four tuple constructions
      as text on both sides, so the reseed stops classifying every stored grant as stale.
- [ ] **U2**: key `@current_scope_roles` per the B1 decision above (controller-only
      normalization, or String key plus `user.id.to_s` in the view).
- [ ] **U3**: the gem-upgrade files, already committed in B2.
- [ ] Regression coverage, each seen red before the fix per the repo's
      prove-every-new-test-fails rule:
  - `test/.../role_seed_test.rb`: id-list equality across a second `migrate!`, a
    no-duplicate count assertion, `Lead` as well as `Manager`, pruning still works,
    dry-run still writes nothing.
  - `test/.../users_index_test.rb`: badge renders, no stray badge, turbo_stream path.

### B4. Gate, PR, review

- [ ] Run the full **Step 3** gate on the PR-head SHA, including the local CI block for
      `miela_app` and the gate-record file.
- [ ] Live reseed check: `DRY_RUN=1 bin/rails current_scope:migrate_roles` first, then
      the real run, then confirm `CurrentScope::ScopedRoleAssignment.count` is unchanged.
- [ ] Browser check, with the precondition the plan sets (`CurrentScope::RoleAssignment`
      must return a non-empty list for the users on page 1, or the page is legitimately
      blank and the check proves nothing): `/dev-portal/users` shows "Owner" for the user
      whose stored subject id is `"1"`.
- [ ] **Step 4**: `gh pr create --base release/phase-6`.
- [ ] **Step 5** and **Step 6**: bots settle, lenses re-run, every thread answered inline
      with `**Claude:**`, CI green, then stop.

---

## Stage C, PR 2: `miela_app` issue #758 (the flip blocker)

**Issue #758:** "CurrentScope gate runs BEFORE authentication, so flipping to `:enforce`
turns every signed-out visit into a 403".

**Plan:** `/Users/davidteren/Projects/VA/miela_app/docs/plans/2026-08-24-002-fix-authentication-before-current-scope-gate-plan.md`

**Verdict:** needs_revision. Four must-fix items, all of them about proving a sweep the
plan currently asserts. The fix itself (one line moved, six deleted, four skips added, one
`main_app.` prefix) is not in question.

**Why this is a blocker, and why the report cannot see it.** On `DashboardsController`,
counting `before` callbacks only, `current_scope_check!` is number 7 and
`require_authentication` is number 11. That was measured at runtime, not inferred.
`ApplicationController` does `include CurrentScope::Guard` at line 25, while
`require_authentication` is declared per subclass (`dashboards_controller.rb:4`,
`time_entries_controller.rb:4`, `profiles_controller.rb:6`, `admin/base_controller.rb:7`,
`manage/base_controller.rb:5`, `manager/base_controller.rb:7`), so it is appended after the
gate and runs second. In `:report` nobody notices: the gate downgrades, the ledger row is
dropped because there is no actor, and `require_authentication` then redirects to sign-in.
Under `:enforce` the same request raises `CurrentScope::AccessDenied` at callback 7 and
never reaches callback 11. `bin/rails current_scope:report` can never warn about this, at
any traffic volume, because `record_would_deny_event` returns early when there is no
subject.

### C1. Resolve the must-fix list in the plan file

- [ ] **G1. Prove the public-controller sweep instead of asserting it.** KTD-3 (plan line
      151) lists four public controllers with no stated method and no runtime evidence,
      while every other load-bearing fact in that plan carries a "Verified at runtime"
      entry. The four are **correct**: they were re-derived on 2026-08-24 while this
      runbook was written. Add the command and its output to the plan's "Verified at
      runtime" list as fact 6, so the next reader can re-run it rather than trust it:

```bash
cd /Users/davidteren/Projects/VA/miela_app
bin/rails runner '
Rails.application.eager_load!
def before_syms(k)
  k._process_action_callbacks.select { |c| c.kind == :before && c.filter.is_a?(Symbol) }.map(&:filter)
end
hosts = ApplicationController.descendants.reject { |k| k.name.nil? }
puts hosts.reject { |k| before_syms(k).include?(:require_authentication) }.map(&:name).sort'
```

      Output on `chore/current-scope-bake-116`: 37 descendants, 10 of them without the
      callback. Four are the host controllers KTD-3 names (`MagicLinksController`,
      `PagesController`, `SessionsController`, `TestHelpersController`). The other six are
      the engine controllers in G3.

- [ ] **G2. State that the sweep covers `ApplicationController` descendants only, and
      record what lies outside it.** Three routes serve anonymous traffic from other base
      classes, and the plan never mentions them: `/up` (`Rails::HealthController`, the
      Kamal and load-balancer health check), and `/manifest` and `/service-worker`
      (`Rails::PwaController`, which the browser fetches from the signed-out sign-in page).
      Verified at runtime: `Rails::HealthController` inherits `ActionController::Base`
      directly, and `Rails::PwaController` inherits `Rails::ApplicationController`, which is
      itself an `ActionController::Base` subclass. **One correction to the critique that
      raised this:** it says all three inherit `ActionController::Base`; for
      `Rails::PwaController` that holds only indirectly. The conclusion does not change.
      Neither is an `ApplicationController` descendant, so the new callback cannot reach
      them, and the same is true of the ActiveStorage, ActionMailbox, `Rails::Mailers`,
      `Rails::Info` and `Turbo::Native::NavigationController` routes. **The plan is safe.**
      Write the check down anyway: as it stands, "we checked and they are out of reach" and
      "we never considered the health check" read identically.

- [ ] **G3. Name all six CurrentScope engine controllers that gain authentication.** KTD-4
      (plan line 166) and R4 (plan line 105) both speak of "a signed-out visit to
      `/current_scope`" as if it were one endpoint. Verified at runtime, six controllers
      lack `require_authentication` today and all six inherit `::ApplicationController`:
      `CurrentScope::ApplicationController`, `CurrentScope::EventsController`,
      `CurrentScope::RolesController`, `CurrentScope::RoleAssignmentsController`,
      `CurrentScope::ScopedRoleAssignmentsController`, `CurrentScope::SubjectsController`.
      Say that the accepted behaviour change (the gem's access-denied page becomes a
      sign-in redirect) covers the **whole mount**, including its non-GET endpoints, where
      `store_location` writes nothing: `app/controllers/concerns/authentication.rb:98-100`
      stores `request.fullpath` only when the request is GET or HEAD, so a signed-out POST
      into the engine returns to the default page after sign-in, not to what it tried to
      do. Verified in the source.

- [ ] **G4. Add a test that pins the public set from the public side.** The U3 order-pin
      test proves only "gated implies authenticated". It cannot fail when the skip list
      grows, and its scenario "the four public controllers carry neither callback" restates
      the same hand-written four that G1 says is unproven, so it is a tautology against its
      own input. In `test/controllers/authentication_callback_order_test.rb`, walk
      `ApplicationController.descendants`, collect the ones whose before-chain lacks
      `require_authentication`, and assert **set equality** against a named allowlist
      constant. Comment that constant with the fact that adding a name to it opens an
      unauthenticated surface. After U2 that set is exactly the four public host
      controllers, because the six engine controllers inherit the callback from
      `ApplicationController`. Write the constant against the **post-U2** set, not against
      the ten names G1 prints today.

### C2. Branch, and correct the branch the plan names

The plan header says the branch is `chore/current-scope-bake-116`. That is wrong once Stage
B renames that branch to `fix/757-current-scope-string-ids` and merges it. One issue, one
branch, one PR. Fix the header while you resolve C1.

```bash
cd /Users/davidteren/Projects/VA/miela_app
git checkout release/phase-6 && git pull      # #757 must already be merged
git checkout -b fix/758-authentication-before-current-scope-gate
git add docs/plans/2026-08-24-002-fix-authentication-before-current-scope-gate-plan.md
```

### C3. Implement

- [ ] **U1 first, on its own.** Prefix the redirect in
      `Authentication#require_authentication` with `main_app.`, so the sign-in redirect
      cannot raise `ActionController::UrlGenerationError` inside the namespace-isolated
      engine. Land it before U2 so the engine cannot 500 for even one commit. Prove the
      raise first: remove the prefix and watch the new test fail.
- [ ] **U2 as one atomic change.** Declare `before_action :require_authentication` on
      `ApplicationController`, above `set_current_scope_subject` and above
      `include CurrentScope::Guard`. Delete all six subclass declarations. Add
      `skip_before_action :require_authentication`, with a one-line reason, on the four
      public controllers. Do not split this: adding the parent declaration without the
      skips redirects the sign-in form to itself, and adding the skips first references a
      callback that does not exist yet and raises at class load. On `ProfilesController`
      delete only the `require_authentication` line; the three callbacks below it stay
      where they are.
- [ ] **All six deletions are load-bearing.** A subclass that re-declares the callback
      removes the inherited one and appends its own at the end of the chain, which puts
      authentication back behind the gate on exactly that controller. Partial deletion
      looks done and fixes nothing there.
- [ ] **U3.** The order-pin test, the `:enforce` readiness test, the hoisted
      `with_enforcement` helper, and the G4 allowlist assertion. Every new test is seen red
      first: the order pin must fail with `require_authentication` at index 11 and
      `current_scope_check!` at index 7, and the readiness test must fail with a 403.
- [ ] **U4.** Add the cleared precondition to
      `docs/plans/2026-08-07-001-feat-currentscope-u5-enforce-flip-plan.md`, citing #758.

### C4. Gate, PR, review

- [ ] Full **Step 3** gate on the PR-head SHA, with the `miela_app` local CI block and the
      gate-record file.
- [ ] **Step 4**: `gh pr create --base release/phase-6`. The body says in plain
      words that the change is behaviour-neutral in `:report`, and names the two
      observability details that stop appearing on anonymous requests: the
      `report-only: would DENY` log line and the `X-Current-Scope-Reason: would_deny`
      response header.
- [ ] **Steps 5 and 6** as written in section 3.

---

## Stage D, PR 3: `current_scope` issue #190

**Issue #190:** "`current_scope:report` counts denials on DELETED records as outstanding
for ever, so the exit condition is still unreachable."

**Plan:** `/Users/davidteren/Projects/DT/current_scope/docs/plans/2026-08-24-001-fix-report-moot-vs-unknown-plan.md`

### D1. Nothing to resolve: the plan came back ready

The re-validation verdict on
`/Users/davidteren/Projects/DT/current_scope/docs/plans/2026-08-24-001-fix-report-moot-vs-unknown-plan.md`
is **ready**, with **no** remaining must-fix items. Everything the first pass asked for is
in the plan now: the caller shape beside the `locate` lambda and the contract that
`allow?(record:)` only ever receives an ActiveRecord object or `nil`; every test arm
labelled **CHANGE-DETECTING** (proved red against `main`) or a regression pin (proved green
against `main`); the moot-only output specified end to end, including the decision to guard
the "nothing found in any category" line with the moot bucket; the units named on every
number, with `moot.sum { |pair| pair[3] }` for denials and `resolved.count` for pairs; the
two `docs/guides/adopting-in-an-existing-app.md` anchors (`:49-58` and `:406-413`) added to
the line-anchor refresh list; the rollout-ladder decision at `:406-413`; the soft-delete
trade named against `AGENTS.md` hard rule 1 ("Fail-closed is the product") and accepted in
the plan itself; and the in-repo precedent at
`app/helpers/current_scope/application_helper.rb:149` cited rather than restated.

One thing carries out of the plan and into this runbook, so it is repeated here: the honest
claim is that the fix makes zero **reachable**, not that the count reaches zero. On the bake
host the reading goes from 1029 outstanding to 679, with 350 denials on the new moot line.

### D2. Branch and implement

```bash
cd /Users/davidteren/Projects/DT/current_scope
git checkout main && git pull
git checkout -b fix/190-report-moot-vs-unknown
git add docs/plans/2026-08-24-001-fix-report-moot-vs-unknown-plan.md
```

- [ ] **U1**: change the `locate` lambda in `lib/tasks/current_scope_tasks.rake` to
      return `:moot` / `:unknown`, and let the caller decide what each means. A recorded
      denial whose target GID raises `ActiveRecord::RecordNotFound` is **MOOT**: the
      class loaded, the row is gone, the gate can never be asked about it again. A
      denial whose target GID raises `NameError` stays **UNKNOWN** and stays counted as
      outstanding, because "cannot tell is not the same as ready" is still right there.
      The subject is resolved and judged first, so a dead subject stays UNKNOWN whatever
      the target's state, which keeps PR #184's behaviour untouched.
- [ ] **U2**: print the moot line, widen the all-clear guard, and add a "granted or
      moot" wording so the all-clear never claims a moot denial was granted. Include the
      plan's KTD-7 decision about `signals` and the zero-`resolved` wording.
- [ ] **U3**: refresh the adoption guide, the design note that owns this story, and
      `CHANGELOG.md`, including **every** shifted line anchor the note quotes, plus the
      two `docs/guides/adopting-in-an-existing-app.md` anchors (`:49-58` and `:406-413`)
      the plan adds to that refresh list.

### D3. Gate, PR, review

- [ ] Full **Step 3** gate on the PR-head SHA, with the `current_scope` local CI block
      (`bin/rails db:test:prepare`, then `bin/rails test`, then `bin/rails test:system`,
      then `bin/rubocop`) and the gate-record file. Remember `rake test` runs nothing and
      exits 0.
- [ ] **Step 4**: `gh pr create --base main`. Use the word **reachable**, not "reaches
      zero", in the body.
- [ ] **Steps 5 and 6** as written in section 3.

---

## Stage E, PR 4: `current_scope` issue #191

**Issue #191:** "UPGRADING 0.4 → 0.5 is incomplete: no `db:test:prepare`, and the
string-id change is documented as a note rather than a silent breakage."

**Plan:** `/Users/davidteren/Projects/DT/current_scope/docs/plans/2026-08-24-001-docs-upgrading-04-05-honesty-plan.md`

### E1. Resolve the must-fix list in the plan file

The re-validation verdict is **needs_revision**, with **two** items left. Everything else
the first pass raised is answered in the plan already: the `maintain_test_schema!`
rationale, the failure-first entry point, the bounded safe-query claim with its raw SQL and
join exception, the named test literals, the KTD6-versus-`DocsSiteTest` ownership question,
the three untouched first-install mirrors, and the runnable grep line for the reader.

- [ ] **E1a. KTD3 rests on a premise that is false, and the cut it justifies leaves the new
      step list wrong for MySQL hosts.** KTD3 (plan line 143) cuts the MySQL test-database
      sentence for two stated reasons: "the bake host was PostgreSQL, so no evidence
      supports it", and "the existing 'If your database was built from `schema.rb`'
      subsection already covers the collation for the hosts it applies to". **Neither
      holds, and both were checked against this repository rather than against the bake:**

  - The evidence is in this repository, not in the bake.
    `lib/tasks/current_scope_tasks.rake:9-12` names `db:test:prepare` itself as one of the
    schema-load paths that produce "the right column TYPE and the server's default
    collation, because schema.rb cannot express a MySQL collation".
    `lib/current_scope/schema_guard.rb:101-102` says the same thing in its own comment: "A
    database built from schema.rb has the right column type and the wrong collation, which
    is the common case for a new app and for CI."
  - The consequence is mechanical. `db:test:prepare` loads `db/schema.rb`; `schema.rb`
    cannot carry a MySQL collation; the test columns come out `utf8mb4_0900_ai_ci`; and
    `check_collation!` at `lib/current_scope/schema_guard.rb:144` raises
    `CurrentScope::ConfigurationError` at boot. **A MySQL host who follows the plan's new
    three-command list still cannot run `bin/rails test`**, which is the exact failure the
    plan exists to remove.
  - The existing subsection does not cover it. `UPGRADING.md:131-144` never says
    `RAILS_ENV=test`, and `current_scope:repair_schema` runs against the current
    environment's connection only, so a reader who follows it repairs development a second
    time and leaves the test database broken.

      Resolve it one of two ways, and write the choice into KTD3 **with the corrected
      premise**, so the next reader does not re-derive this:

  - **(a), the recommended one.** Add one scoped clause to U1, for example: "On MySQL, a
    test database loaded from `schema.rb` has the right column type and the server's
    default collation, so also run `RAILS_ENV=test bin/rails current_scope:repair_schema`.
    A host on `config.active_record.schema_format = :sql` builds the test database from
    `structure.sql`, which carries the collation, and does not need it." That answers
    KTD3's own `:sql` objection by naming the condition rather than by staying silent. It
    is two sentences, and it is supported by code already in this repository.
  - **(b).** Keep the cut, but state the real reason for it and say where the MySQL reader
    is sent instead.

- [ ] **E1b. Broaden the deferral to cover both wrong-prescription messages, not one.** The
      "Deferred to follow-up work" bullet (plan line 132) names only
      `lib/current_scope/schema_guard.rb:95`. A second message has the same defect for the
      same reader: the `check_collation!` raise at `lib/current_scope/schema_guard.rb:144`
      tells the host to run `bin/rails current_scope:repair_schema` with no
      `RAILS_ENV=test`, so a MySQL host who reads it out of a test-environment boot failure
      runs the repair against development and stays broken. That is the same anti-pattern
      the bullet already cites `lib/tasks/current_scope_tasks.rake:14-15` for, and the
      plan's own proposed fix for `:95` ("name the failing connection") fixes both in one
      change. Broaden the bullet, and the follow-up issue it requires, to cover `:95` **and**
      `:144`. As written the plan defers the path the ticket named and leaves the sibling
      unnamed, which is the exact failure mode the plan is otherwise careful about. The
      Definition of Done already requires the follow-up issue number before the PR opens;
      widen that line to the same two messages.

### E2. Branch and implement

```bash
cd /Users/davidteren/Projects/DT/current_scope
git checkout main && git pull            # #190 should already be merged
git checkout -b docs/191-upgrading-04-05-honesty
git add docs/plans/2026-08-24-001-docs-upgrading-04-05-honesty-plan.md
```

- [ ] **U1**: add `bin/rails db:test:prepare` to the "What you must do" command block at
      `UPGRADING.md:103`, with the short reason, the `maintain_test_schema!` explanation
      from E1, and the failure-first search words.
- [ ] **U2**: rewrite "Every host: grant ids now read back as strings"
      (`UPGRADING.md:166`) as a **silent breakage**. Name the three host code shapes that
      break: tuple or Set comparisons against live ids; a hash keyed by `subject_id` then
      looked up with a model id; a bare `==` between a stored id and a model id. State
      that all three exit 0 with no exception. Then clear the safe query forms explicitly,
      bounded as the plan's R5 and KTD5 already state.
- [ ] **U3**: keep the three mirrors from drifting: the site page
      `docs/site/upgrading.md`, the README installation callout, and one `CHANGELOG.md`
      `[Unreleased]` → `### Fixed` entry. **Rebase on `main` after #190 merges** so the
      CHANGELOG hunk is written against the final list.
- [ ] **U4**: add `test/upgrading_doc_test.rb`, slicing the 0.4 → 0.5 section and pinning
      the literals the plan already names (`bin/rails db:test:prepare`, and
      `where(subject_id: user.id)` inside the string-id subsection), in the style of
      `test/docs_site_test.rb`.
- [ ] No engine code, no new rake task, no doctor command. Both `schema_guard.rb`
      messages stay as they are and are handled by the follow-up issue E1 requires.

### E3. Gate, PR, review

- [ ] Full **Step 3** gate on the PR-head SHA (documentation-only is **not** a waiver),
      with the `current_scope` local CI block and the gate-record file.
- [ ] **Step 4**: `gh pr create --base main`.
- [ ] **Steps 5 and 6** as written in section 3.

---

## Stage F: What no plan owns, and what actually closes #116

The four PRs above do not close the bake. Three things remain after them, and none of
the three is owned by a plan.

**What used to be here.** The authentication-ordering blocker was written up in this
section when no plan owned it. It is now issue #758 with its own plan, and it is
**Stage C** above. Nothing about it is left in this stage.

### F1. Re-pin the gem and re-bake (this is the evidence #116 asks for)

`miela_app`'s `Gemfile:54` pins `ref: "8036b33..."`, and plan #757's KTD3 ships that pin
as-is. So after all four PRs merge, the bake host still runs a gem **without** the moot
fix, and still reads 350 permanently outstanding denials. This step is the one that turns
#190 into evidence, and no plan owns it.

After **#190 merges to `current_scope` `main`**:

- [ ] Bump the `miela_app` pin a second time, to the new `main` SHA. This is a fifth
      pull request: its own branch off `release/phase-6`, its own Step 3 gate, its own
      Steps 5 and 6.
- [ ] Re-run `bin/rails current_scope:report` on the host, against that new pin.
- [ ] **Record the reading.** The outstanding count falls from **1029 to 679**, with the
      remaining **350** denials printed on the new moot line. Quote all three numbers.
- [ ] Post that reading on issue #116, and say what it means in one sentence: the fix
      makes zero **reachable** on a host that deletes records; it does not by itself make
      the count zero.
- [ ] If the numbers come back different from 1029 / 679 / 350, do not paper over it.
      Post what you actually read and say why it moved (rows added since the first read,
      or a wrong classification).

### F2. Re-scope issue #187

Issue #187 ("`current_scope:report` should answer 'am I ready to flip?', not just 'what
is outstanding?'") **stays deferred**. It assembles signals that already exist and it
changes no count, so it is not on the #116 critical path.

- [ ] But its body claims the auth-ordering gap is unsurfaceable. After the Stage C work
      it is statically answerable per host: the order-pin test in #758 answers it from the
      callback chain, with no traffic needed. Re-scope #187 to the **preflight task only**
      and edit that claim out, citing `miela_app` #758.

### F3. Preconditions for the `:enforce` flip

The flip is last, and it has **exactly two** preconditions. Both must hold. Neither
substitutes for the other.

- [ ] **Precondition 1, the report reading is zero or explained.** After the Stage F1
      re-bake, `bin/rails current_scope:report` reads zero outstanding, or it reads a
      number where every line is accounted for: moot rows understood as denials on
      deleted records, unknown rows triaged one by one. A number nobody can explain is
      not a pass.
- [ ] **Precondition 2, issue #758 is merged.** The Stage C authentication-ordering fix
      is on `release/phase-6`, its order-pin test and its `:enforce` readiness test are
      green, and the flip plan records the cleared precondition. No report number can
      stand in for this: an unauthenticated would-be denial is never written to the
      ledger (`record_would_deny_event` returns early with no actor), so the report
      cannot see this problem at any traffic volume.

Only then does `config.enforcement = :enforce` go in, per
`docs/plans/2026-08-07-001-feat-currentscope-u5-enforce-flip-plan.md`: test environment
first, then staging, then production.

---

## 4. What "done" means

### Done for the four findings

All four PRs merged by the human (Stages B, C, D, E), each with CI green on its head SHA and
every review thread answered inline.

### Done for the #116 real-host bake

1. The four PRs are merged: #757 and #758 in `miela_app`, #190 and #191 in `current_scope`.
2. The gem pin is bumped a second time to a `current_scope` `main` that contains #190, and
   `bin/rails current_scope:report` is re-read on the host (Stage F1). That is a fifth PR.
3. The reading is posted on issue #116: outstanding falls from **1029 to 679**, with **350**
   denials on the moot line, and the sentence saying the fix makes zero **reachable**.
4. Both flip preconditions hold (Stage F3): the report reads zero or reads a number where
   every line is explained, **and** issue #758 is merged with its tests green.
5. `config.enforcement` is flipped to `:enforce` on the real host and it stays up, per
   `docs/plans/2026-08-07-001-feat-currentscope-u5-enforce-flip-plan.md`: test environment
   first, then staging, then production.
6. The flip result is written on issue #116, which ticks the Wave 3 checkbox: "One real host
   runs report mode, reads `current_scope:report`, then flips to `:enforce`."

### Done for the README Beta banner (#116 Wave 3, the last item)

After the flip, one item remains on #116: **"Final PR: remove the README banner and
badge, update `STATUS.md`, cut the next release."** That is a sixth PR, and it is the last
one.

- [ ] Remove the not-production-ready banner and badge from `README.md`.
- [ ] Update `STATUS.md`, including the stale line that still says the 0.4.0 RubyGems
      publish is pending.
- [ ] Cut the next release. Per `AGENTS.md`, a version bump or RubyGems tag first runs the
      milestone gate: `dte-deep-reviewer`, then `dte-test-auditor`, then
      `/security-review`.
- [ ] That final PR runs the same section 3 gate. It is not exempt.

---

## 5. Standing rules that apply to every step above

- **Never merge, and never suggest merging**, while any check or any thread is
  outstanding. The human merges.
- **PRs always.** No direct pushes to `main` (`current_scope`) or to `release/phase-6`
  (`miela_app`).
- **The gate is per PR**, on the exact head SHA, and any later commit voids it.
- **`rake test` in `current_scope` runs nothing and exits 0.** `bin/rails test` is the
  real command.
- **Every remote comment starts with `**Claude:**`.** `gh` posts under David's account.
- **Findings and replies stay inline** on the code. No floating PR summary comment. Roll
  the counts up in chat.
- **A deferral names its GitHub issue number and link.** "Later" alone is not allowed.
