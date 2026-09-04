# Validation findings: the five merged pull requests

Written 2026-09-04 by five fresh agents working from
`docs/reviews/2026-09-04-validation-brief-pr197-201.md`, one slice each, in separate worktrees.
Every test claim below (findings 1 to 7) was established by breaking the
behaviour and reading the test output. Finding 8 and the P3 items were checked
by reading the engine, not the page. All mutations were reverted; nothing was
committed, pushed or posted.

## Verdicts

| PR | Does the code do what the description says? |
|---|---|
| #197 report task asks with the gate's model | Yes. One test pins two predicates instead of the call site. |
| #198 boot refusals name the database | Yes for the message. The adapter predicate the fix rests on is untested. |
| #199 audit every grant write | Partly. Four silent paths are documented; a fifth is not. |
| #200 role-to-resource-type compatibility | Yes. No security gap. The conflict resolution in `scoped_role_assignment.rb` is clean. |
| #201 fit comparison and docs site | Partly. Four chooser behaviours cannot go red; two page claims overstate the engine. |

No P1 was found. The unexplained transient has a root cause and a candidate fix.

**Status (2026-09-04, later the same day):** every P2 below (findings 1 to 7)
and the doc claims in finding 8 are fixed in [PR #202](https://github.com/davidteren/current_scope/pull/202).
The candidate fix for finding 1 grew into `test/support/support_table.rb`,
which rebuilds a support table only when its column names drift, so neither
the concurrent drop nor the stale-schema trap remains.

## Findings, most severe first

### 1. The suite cannot run as two processes in one checkout (the transient)

`test/support/uuid_user.rb:22` and `test/support/identity_user.rb:10` run
`create_table(..., force: true)` at load and `Minitest.after_run { drop_table }`
at exit. Every process shares `storage/test.sqlite3`
(`test/dummy/config/database.yml`). A second process drops the tables under the
first, and the first's exit drops them under the second.

Reproduced twice, including the brief's exact scenario (a system test file
booting while `bin/rails test` ran): 1109 runs, 3 failures, 50 errors, all
`no such table: current_scope_test_uuid_users` or the identity table. Coverage
fell to 94.64%, under the CI floor. The reverse order was green, which is why
the original run saw 6 errors once and nothing in nine reruns. CPU load alone
(eight burners, three seeds) produced no errors.

Candidate fix, tried and green: in both support files change `force: true` to
`if_not_exists: true` and delete the `after_run` drop. A per-PID database name
does not work, because `rails/test_help` prepares the schema in a child process
with its own PID. Add "one test process per checkout" to `AGENTS.md` either way,
since a SQLite `BusyException` remains possible past the 5 s timeout.

Same hazard, not observed failing: `test/definitions_import_test.rb:336` and
`test/generators/*_test.rb` write fixed repo paths.

### 2. #198: the MySQL predicate is untested and a wrong answer fails open

`CurrentScope.mysql_config?` (`lib/current_scope.rb:439`) is what decides
whether the collation check runs. Making it return `false` unconditionally left
the guard tests green (0 failures) because every MySQL test stubs
`SchemaGuard.mysql?` directly. On a real MySQL host, `false` skips
`check_collation!` entirely and the #151 case-folding escalation stays live with
no refusal. The CI MySQL matrix would not catch it, since the dummy app boots
fine when the check is skipped.

### 3. #199: a fifth silent path, and the rollback guarantee has no test

`app/models/current_scope/scoped_role_assignment.rb:32-33` declares only
`after_create` and `after_destroy`. `grant.update!(role:)`, `update!(subject:)`
or `update!(resource:)` re-points a live scoped grant and writes no ledger row.
`docs/guides/configuration-reference.md:149-159` and `CHANGELOG.md:134` say four
paths are silent and omit this one. Line 123 of the same guide says two.

The PR says the callbacks run inside the transaction so `audit = :strict` rolls
the grant back. True today, but adding `rescue StandardError; nil` after
`Event.record!` in `app/models/concerns/current_scope/audited_writes.rb:54-59`
left all 1109 unit runs green. Existing strict tests call `Event.record!`
themselves. One test closes it: `ScopedRoleAssignment.create!` with
`Event.create!` raising, assert count 0.

### 4. #197: the "records no model key at all" path is unpinned

`test/integration/report_only_test.rb:152` asserts `unnameable_model?` and
`recordable_model_name` individually. Deleting
`unless unnameable_model?(record, model)` from `lib/current_scope/guard.rb:498`
left the file green (47 runs). Without it an anonymous ActiveRecord class is
recorded as `model: nil`, which the report reads as "the gate had no type" and
re-checks on the stricter question with no caveat. That is the false denial the
PR describes, in the one shape the report cannot flag.

### 5. #201: the reveal test depends on network egress (the third environment case)

`test/system/docs_site_reveal_test.rb:37-47` says it does not wait on the remote
badges. It does. `Ferrum::Page#go_to` waits up to the 60 s timeout for the main
frame to stop loading and raises `PendingConnectionsError` on pending requests
(`pending_connection_errors` defaults to true). With the four remote requests
(two shields.io badges, the GitHub badge, the RubyGems JSON) intercepted and
never continued, `go_to` hung for the full timeout. A runner that drops packets
rather than failing DNS fast errors all 5 reveal tests at 60 s each. Fix:
intercept and abort `http*` requests in setup, or pass
`pending_connection_errors: false`.

### 6. #201: four chooser behaviours the PR describes cannot go red

All in `docs/site/comparison.md`, tested by
`test/system/docs_site_fit_chooser_test.rb` (7 runs, 0 failures after each):

- Ties shown as ties: line 568 `ranked.filter(...)` replaced with
  `ranked.slice(0, 1)`. Survived.
- Veto notes on a named verdict: line 596 `if (state.vetoes.length)` replaced
  with `if (false)`. Survived. The reader is never told why CurrentScope was
  ruled out.
- Runner-up cost line: line 617 `givesUp` removed. Survived.
- Pundit weakly dominated again: line 317 `{ pundit: 4, action_policy: 4 }`.
  Survived. Pundit is a sole winner only through the beta veto.

### 7. #200: the report test pins the count, not the listing

`test/report_task_test.rb:890-891` "a grant its type would refuse today is
named". Replacing `unless nonconforming_grants.empty?` with `if false` in
`lib/tasks/current_scope_tasks.rake` left it green. The first regex matches the
summary count line. The second matches the same grant printed by the "can never
match" section, because the fixture's `projects#show` is not a routed key in the
dummy app. Fix: assert the section heading and the line under it, and use a
routed permission key.

### 8. Fit page claims that overstate the engine (`docs/site/comparison.md`)

- Lines 57-59 and row 110: "every grant and revoke lands in an append-only
  ledger". A direct `RoleAssignment.create!` writes no row; only `grant!` and
  the console record `org_role.assigned`. `update_all`, `delete_all` and raw SQL
  bypass append-only.
- Lines 60-64: the SoD bypass is described as a hook a host implements. It needs
  `config.allow_sod_bypass = true`, the hook, and the initiator holding the
  grantable `bypass_sod` key (`resolver.rb:319-354`). So it is a permission. The
  ledger write is a no-op with `config.audit = false`.
  `docs/site/separation-of-duties.md:193` states all three conditions.
- Lines 171-176: report mode "allowed through and written to the ledger". A
  request with no resolved subject is downgraded and recorded nowhere
  (`guard.rb:449`). `:model_undeclared`, `:model_invalid` and
  `:impersonation_gate` still 403 in report mode; only `:no_grant` is downgraded
  (`guard.rb:326-330`).
- Lines 53-56: "a grant on a project covers that project's reports". Only a role
  that ticks the key; scoped full_access does not cascade
  (`resolver.rb:463-470`).
- Line 181 "creates no roles" is right; the rake `desc` at
  `current_scope_tasks.rake:137` still says "into a starter role grid".

### 9. Smaller items (P3)

- #200: a pre-existing grant a new declaration would refuse looks like ordinary
  live access in the console (`roles/members.html.erb:107`,
  `subjects/index.html.erb:91` label only orphaned rows). Only the rake report
  names it and it offers no revoke path. By design per the PR; no in-console
  signal.
- #200: `lib/current_scope/grantable_roles.rb:165` `name.present? &&` is dead;
  `Role` validates presence.
- #197: `lib/tasks/current_scope_tasks.rake:354` "name survives but the resolver
  refuses it" branch is untested; the row lands in `outstanding` instead of
  `unknown`.
- #198: `schema_guard.rb:209` (rescue prints "the test database" with no name)
  and `:220` (empty prefix in development) have no deliberate test.
- #199: two handles to one grant, both destroyed, write two
  `scoped_role.revoked` rows. Pre-existing.
- #197 drift question: the report gets the gate's model by name round-trip
  (`guard.rb:498` writes `model.name`, `rake:345` constantizes). Usability
  cannot drift because both sides ask `resolver.collection_type?`; identity can
  (a `self.name` override, duplicate constants across reloads). Exposure is the
  record-less arm only.

## Checked and clean

- `scoped_role_assignment.rb` conflict resolution (c20f27b): the squash equals
  the merge commit exactly; every hunk from both parents is present; runtime
  reflection confirms public versus private membership, the validate chain and
  both audit callbacks.
- #200 security: fail-closed for declared type with unlisted role, empty
  declaration, nil role and unknown token; undeclared type allowed and pinned as
  the opt-in contract; `resolver.rb` untouched, SoD veto probed independently
  and holds; a grant that outlives the rule is honoured by design and pinned,
  fails a plain `save!`, and can still be destroyed. Both action-required
  threads on #200 re-tested and confirmed false positives.
- #199: every grant writer enumerated with its audit path; no `update_all`,
  `delete_all`, `insert_all`, `update_column` or raw SQL touches a grant table;
  11 transaction probes show no audit-without-write and no write-without-audit;
  impersonation attribution correct.
- About 45 mutations across the five slices went red with the advertised
  message (listed in each agent's transcript).
- Unit suite: 16 seeds idle, two worker settings, three CPU-contention runs, all
  green. No `sleep`, `Timeout` or wall-clock assertion. Global-state mutations
  restore in `ensure` or `teardown`. Capybara uses a random port.
- Docs-site browser tests: theme and reveal mutations 14 of 14 red; no `Date`,
  `Intl` or locale reads; `Emulation.setEmulatedMedia` honoured on Chrome
  152.0.7977.76; fresh user-data-dir per browser so localStorage cannot leak;
  the chooser regex reconstruction has nothing Liquid would touch today.
- Report mode, SoD ordering, console `require_full_access!`, `scope_for`
  returning a relation, five hops, and composite subject identity confirmed on
  `main` as the page states.
