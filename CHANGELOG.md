# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Opt-in role-to-resource-type compatibility (#183).** Any role could be
  granted on any resource type, and with parent-chain resolution an incompatible
  pairing widens access silently: a role whose bundle covers one record's own
  surface, granted on a CONTAINER that record declares as its
  `current_scope_parent`, resolves for every record inside that container. One
  wrong pick in a dropdown, and nothing objected.

  A type may now declare what it accepts:

  ```ruby
  class Workstream < ApplicationRecord
    include CurrentScope::Scopeable
    current_scope_grantable_roles "Lead"
  end
  ```

  `ScopedRoleAssignment` refuses a pairing the type does not list, so a seed, a
  rake task and a console one-liner meet the same rule as the management UI. The
  picker chooses the role first, so it narrows the TYPE list to those that accept
  it and says how many were withheld and why, rather than silently shortening a
  dropdown.

  **Absent a declaration nothing changes**: every role stays grantable on every
  type, which is what every existing host has. The declaration lives on the
  resource rather than on the role, because that is already where a host says how
  a model participates (`current_scope_parent`, the searchable scope,
  `Scopeable`); it needs no migration and no admin screen, and it is versioned in
  the code review that introduces the pairing. `CurrentScope::GrantableRoles` is
  includable on its own for a type that wants the rule without appearing in the
  picker.
- **Portable role-definition export/import (#156 v1).** YAML document of role
  names, descriptions, `full_access`, and permission keys, with diff, a confirm
  gate on production or a populated roles table, snapshot rollback, and ledger
  events `definitions.applied` / `definitions.rolled_back`. Assignments stay
  out (v2). Rake: `current_scope:definitions:export|diff|import|rollback`.
  Import reads `FILE=` and `CONFIRM=1`. Rollback reads `SNAPSHOT=`.
- **Configurable subject identity (#158).** `config.subject_identity` accepts
  a Symbol (one column), an Array of symbols (a composite list, never a
  joined string), or an object with `identify` / `resolve`. Default is the
  primary key. Duplicate natural keys raise at boot. `resolve` never
  inserts. Generator `current_scope:identity` and rake tasks
  `current_scope:identity:check` / `current_scope:identity:setup` (dry-run
  unless `WRITE=1`; `PLACEHOLDER=1` refused in production). This is not
  `config.subject_label`. Assignment export is still issue #156 v2.

  Details worth knowing before you adopt it:

  - **`identity:setup` may not boot on an unrepaired #151 schema, and
    `identity:check` may.** `setup WRITE=1` calls `CurrentScope.grant!`, which
    writes grant rows and does not re-check the schema, because the check runs
    once at boot. Run `current_scope:repair_schema` first if boot says so.
    `check` only reads the host's subject table, so it stays exempt.
  - **A blank identity column raises instead of minting a dead key.**
    `identify` used to turn `nil` into `""`, and `resolve` treats a blank part
    as no key at all, so an export could carry a key nothing would ever
    resolve. One definition of "blank" now covers Ruby and SQL alike, so a
    whitespace-only value is consistently a non-key rather than a collision.
  - **A unique index now answers the boot uniqueness check outright.** For a
    Symbol or Array identity, a plain unique index on exactly those columns
    means the subject table is never scanned, which is what makes the boot error's
    own "add a unique index" advice worth taking. Without an index it is a
    grouping query over the subject table (issue #171 tracks bounding that).
    An identity OBJECT owns its `unique?`, so boot pays whatever it costs.
    Nothing is cached between calls, so `identity:check` always reads the
    table rather than reporting boot's snapshot.
  - **`identity:check` never prompts**, so it is safe in CI, cron, and deploy
    hooks. Both tasks turn an operator mistake (a misspelled `IDENTITY`
    column, a composite `SUBJECT` of the wrong length or with a blank part)
    into a task error rather than a stack trace, and an unlistable duplicate
    now says so instead of printing the literal key `"(duplicate natural key)"`.

### Changed
- **CI now fails when line coverage falls below 95% or branch coverage
  falls below 80% (#146).** Local runs, including a single-file run, do
  not enforce the floor. Reproduce with `CI=1` in front of the documented
  `SIMPLECOV_COMMAND_NAME` commands.
- **Polymorphic registry internals (#163).** One map with `claim!` as
  the collision net, no `owner:` keyword on `polymorphic_class`, and the
  registry extracted to `CurrentScope::PolymorphicRegistry`. Public
  facade methods are unchanged.
- **Members page distinguishes inert org-wide holders from deleted
  subjects (#164).** An unmapped token or non-canonical id is badged
  inert. A missing row reads "subject deleted". The add list no longer
  claims every subject already holds the role when no subjects exist.
- **Docs site landing page is now a conversion page, not only a long
  technical write-up.** Hero CTAs (Star / Quickstart / Showcase / Docs),
  a theme-aware permission-grid mock, real screenshots plus SoD and
  report-mode proof, a CurrentScope vs Pundit / CanCanCan / Action Policy
  table, who-it-is-for copy, a sticky nav that works on a phone, badges,
  a public security strip, and a footer with version, license, author,
  contribution invite, and the X account. Beta copy invites report-mode
  pilots.

### Fixed
- **`current_scope:report` tells a moot denial from one it cannot re-check
  (#190).** Every failed lookup of a recorded denial's target landed in one
  "could not be re-checked" bucket and was counted as outstanding, so a denial
  naming a deleted record stayed outstanding for ever and no grant could clear
  it. On any host that deletes records, that left the exit condition
  unreachable again, one layer down. A target that raises
  `ActiveRecord::RecordNotFound` is now moot: the class loaded and the row is
  gone, so the gate can never be asked about that record again. Those denials
  print on a line of their own and stay out of the headline count and the
  grant-these list. A target whose class no longer resolves, and a subject
  that no longer resolves, still count as outstanding, because cannot tell is
  not the same as ready. This makes zero reachable; it does not make the count
  zero. On the #116 bake host the reading falls from 1029 outstanding to 679,
  with 350 denials moving to the moot line. A host that soft-deletes
  (`acts_as_paranoid`, `discard`, or any row-hiding `default_scope`) reads a
  hidden row as moot too; the moot line and step 5 of the rollout ladder both
  say so.
- **`current_scope:report` names the blind spot that 403s first (#116).** All
  three report-mode recorders skip a request that resolved no subject, because
  the ledger requires an actor. That is the class of denial an operator meets
  first after flipping to `:enforce`, and it could never appear in the survey, so
  a clean report read as "ready" while unauthenticated traffic was untested. The
  caveat now says so in the same breath as the counts.
- **`current_scope:report` now has an exit condition (#116).** The ledger is
  append-only, so a would-be denial survives the grant that fixes it. The report
  counted rows, which answers "what was ever denied", while an operator deciding
  whether to flip to `:enforce` needs "what would still be denied". The guide told
  them in three places to grant until the list empties, and it never could. The
  report now re-checks every recorded denial against live grants, once per
  distinct subject and permission, and counts only the ones still outstanding.
  That count reaches zero. A denial that cannot be re-checked, because its subject
  no longer resolves, counts as outstanding rather than ready.
- **The management console degrades instead of 500ing on a poisoned polymorphic
  registry (#166).** A registry that cannot say which class a token names used to
  raise out of every labeling lookup, so the roles members and subjects pages
  returned a 500: the console died exactly when an operator opened it to find the
  broken grants. Those lookups now pass `inert_on_error: true`, so a row degrades
  to inert through the same path a stale token already takes, and the page shows
  a banner naming the misconfiguration. Writes stay fail-closed: a grant cannot be
  saved under a poisoned registry, and the refusal now names the real cause rather
  than reporting the token as unmapped.
- **Scoped grants on a business primary key match that record (#150).** A
  model that sets `self.primary_key` to a column other than `id`, while
  keeping a leftover surrogate `id`, is covered by tests. Composite and
  nil keys stay refused. No second column migration; #151 already stores
  ids as strings.
- **A chained rake command no longer carries a non-exempt task past the #151
  boot guard.** `SchemaGuard.running_a_database_task?` asked whether ANY task on
  the command line was allowed to boot without the repaired grant-column shape.
  Rake takes a list, so one exempt name exempted everything beside it:
  `bin/rails current_scope:identity:check current_scope:identity:setup WRITE=1`
  booted through and wrote grants on the vulnerable columns, and
  `bin/rails db:migrate db:import_users` let a host's own task inherit the
  exemption the file's exact-name rule exists to deny it. The allow list is now
  unanimous — every task in the invocation must be exempt, or none of them is.
  The refusal list is unchanged: one refused task still vetoes the whole
  command. This is defence in depth rather than a remote exposure (it needs an
  operator to chain the tasks deliberately at a shell), so no advisory is
  issued, but it is the guard the #151 fix depends on.
- **`CurrentScope.identify_subject` refuses a record that is not
  `config.subject_class`.** `resolve_subject` only ever returns that class, so a
  key minted from another model with the same column value resolved to a
  different record in the next environment, silently, holding whatever grants
  that record held.
- **Custom `polymorphic_name` tokens now match on the list and the members page (#155).** Collection, ancestor, and record-less write lookups use the stored token (`polymorphic_name`), not `base_class.name`. Reverse lookup uses a closed registry (Rails first, then auto-detected overrides plus optional `config.polymorphic_class_names`). Two classes that claim the same token raise at rebuild, including a shortened name that matches another loaded class. Config may only name a class that actually stores that token. An unmapped token stays inert.
- **The public resolver picture now matches the six-step order the engine already runs.** README, the docs-site include, and the landing-page steps named a five-step order that skipped the record-less listed-read arm. The Limitations table also still said parent hierarchy was deferred after `current_scope_parent` shipped.
- **The 0.4 to 0.5 upgrade steps now cover the test database and the silent half
  of the string-id change (#191).** "What you must do" listed
  `current_scope:install:migrations` and `db:migrate`, which migrate development
  only, so the next `bin/rails test` aborted at boot on a test database that
  still had the integer columns, and the boot message named the pair the reader
  had just run. The steps now name `bin/rails db:test:prepare`, say why Rails
  cannot repair the test schema itself (the guard runs while
  `config/environment` loads, before `rails/test_help` reaches
  `maintain_test_schema!`), and add the MySQL clause
  `RAILS_ENV=test bin/rails current_scope:repair_schema` for hosts on the
  default `schema_format = :ruby`. "Grant ids now read back as strings" stated
  the type change and stopped; on the #116 bake host that change silently broke
  a grant-syncing seed, which deleted every scoped grant, and an id-keyed hash,
  which rendered every role blank, both at exit status 0. The subsection now
  names the three breaking code shapes, says the failures are silent, clears
  `where(subject: user)`, `where(subject_id: user.id)`, and `scope_for` so
  nobody rewrites a working query, sends raw SQL fragments and joins to a manual
  check, and ends with one grep line. The docs-site page and the README upgrade
  callout carry the same commands.

## [0.5.1] - 2026-08-12

### Changed
- **Readiness banner softened from "not production-ready" to Beta.** The core is
  built and security-hardened; general availability (1.0) is gated on the
  real-host enforce bake (#116). Updated the README, the docs site,
  `docs/site/llms.txt`, the quickstart, and the gemspec description. Also recorded
  the published #151 advisory id (GHSA-944r-4v99-qqf7) in the 0.5.0 entry.

## [0.5.0] - 2026-08-12

`current_scope_parent` (#108) moves authorization semantics: a scoped grant can
reach records it never reached before. It is opt-in, so a host that declares no
chain sees byte-identical decisions — but the version still says a rule changed.
This release also fixes a published security defect (#151, below). The README
banner stays up on purpose: production-readiness is gated on the real-host
`:enforce` bake (#116 Wave 3), not on this release.

### Added
- **A missing `current_scope_initiator` is now found before traffic finds it,
  and accounted for when traffic does (#133).** An action listed in
  `config.sod_actions` reaching a model that defines no `current_scope_initiator`
  raises `CurrentScope::ConfigurationError` on every request — in
  `config.enforcement = :report` exactly as in `:enforce`. That breaks report
  mode's "nothing changes for users" promise at the worst moment, because the
  host cannot see the mistake until live traffic reaches the action.

  **The raise is unchanged**, and deliberately so. Letting the request through
  would execute a separation-of-duties action with the four-eyes veto never
  consulted, and downgrading it to a 403 would dress a misconfiguration up as an
  ordinary denial. What changed is when a host learns about it:

  - **Before traffic.** `CurrentScope::SodPreflight` walks `config.sod_actions`
    against the route-derived catalog and logs one warning naming every action
    whose controller declares a `current_scope_model` that cannot answer
    `current_scope_initiator`. It runs when the route set loads: at **boot** in
    an eager-loading environment (production, staging — where a rollout bake
    runs), and on the **first request** in development, whose route set is lazy.
    Log-only, and a no-op until a host opts into SoD (`config.sod_actions`
    defaults to `[]`).
  - **In the survey.** `bin/rails current_scope:report` gains two sections: the
    static preflight list (present with zero recorded traffic) and the requests
    that actually raised, recorded in report mode as `access.sod_initiator_missing`
    ledger rows naming the permission and the model.

  **The boot list is PARTIAL and says so in its own output.** Only controllers
  declaring `current_scope_model` are inspected, so an action without that
  declaration is absent rather than cleared; and the declared type names what
  the collection lists, so a member action loading a different type is named
  against the wrong model. This is the same limit #134 recorded: which record a
  member action decides about comes from `current_scope_record`, whose value
  exists only mid-request and is not statically knowable. The ledger rows are
  the proof the boot list cannot be.

- **Unresolvable scoped grants are surfaced before the enforce flip (#134).**
  `bin/rails current_scope:report` and the role members view now separate a
  grant that **cannot match** (proven: the role ticks nothing, or only unrouted
  keys) from one worth a **check hooks** look (advisory: no ticked key names a
  controller for that type — the engine cannot prove this, so the output says
  so). Neither is #90's **inert**, which means the record is gone.

  The report sections are derived from the grants table, not the ledger, so they
  print with no recorded traffic. Not on the subjects page yet: the badge
  widened that table past the viewport at narrow widths. No runtime
  `warn_on_*` nudge — this is a pre-flip check, not a per-request one.

- **Parent-record resolution for scoped grants (#108), opt-in.** A model may
  declare `current_scope_parent :project`; when no direct scoped grant matches a
  record, the resolver walks the declared chain and matches grants against its
  ancestors, and `scope_for` lists the same records. This makes "Lead of Project
  7 approves Project 7's reports" expressible without granting per child.

  **This moves authorization semantics, so it is a minor bump, not a patch.** A
  host that declares no chain sees byte-identical decisions.

  Three things to know before declaring one:
  - **A scoped `full_access` grant does NOT cascade.** The ancestor query
    matches only roles that explicitly tick the key. Otherwise one scoped
    `full_access` grant on a root record would open every permission on every
    descendant. The consequence is that privilege stops being monotonic: a
    `full_access` role reaches *fewer* records through a chain than a role that
    merely ticks the key. The role editor's label now says so.
  - **The separation-of-duties veto still reads the record you declared**, never
    an ancestor. The chain feeds grant matching only, so a lead who requested a
    report still cannot approve it. Break-glass does not cascade either: a
    `bypass_sod` grant held on a parent does **not** lift the veto on its
    children, only one held org-wide or on the record itself does.
  - **The declaration is a class macro**, unlike every other `current_scope_*`
    hook, which are plain methods. It has to name an association rather than
    return a record, because `scope_for` builds a query from the foreign key.
    Chains are bounded at 5 hops. A bad DECLARATION raises `ConfigurationError`
    (missing, scoped, polymorphic, `has_many`, or declared on an STI subclass);
    bad DATA never does — an over-deep or looping chain truncates, denies, and
    warns, because a `parent_id` loop is two UPDATEs and must not 500 a request.
- **Grid badge for routes with no controller class (#43).** A stale or typo
  route still appears in the catalog (route mirror), but the role editor now
  marks the row "no controller" so operators do not grant a key that only
  500s with `ActionDispatch::MissingController`. Granting stays allowed;
  remove the route or add the controller.
- **SimpleCov coverage signal in CI (#114).** Suite runs under SimpleCov
  (engine `app/` + `lib/` only); HTML report uploaded as a CI artifact.
  No hard minimum yet — baseline from green runs first.

### Changed
- **The missing-`current_scope_initiator` error names a third fix, and warns
  about one of the others (#108).** A host who declared a *parent* as
  `current_scope_record` (the pre-#108 way to make a scoped grant match) hits
  this error, and the message used to offer "define `current_scope_initiator`
  on the parent" with no caveat. Taking that advice silently blinds the veto:
  it then measures the parent's initiator, never the child's. The message now
  points at `current_scope_parent` on the child and says plainly what the other
  fix costs.
- **Clearer double org-grant error (#44).** A second org-wide `RoleAssignment`
  for the same subject no longer raises the cryptic "Subject has already been
  taken". The validation message names the role already held and points at
  `CurrentScope.grant!` (replace) or scoped roles (additive access).
- **Catalog-miss `ConfigurationError` names the real cause (#44).** Gating a
  permission missing from the catalog now says whether the controller matched
  `config.excluded_controllers` (and which pattern(s)) or is simply not
  routed — two different host fixes.
- **`current_scope_skip_gate!(reason:)` (#76).** Prefer this over bare
  `skip_before_action :current_scope_check!` for deliberate skips. The role
  grid shows **skipped — &lt;reason&gt;** instead of the unexplained "gate not
  run" warning. Bare skips stay alarming.
- **One canonical quickstart (#25).** README Installation, docs site
  quickstart, and `current_scope:install` next-steps share the same path:
  install → concerns → **sessions skip** (or you brick sign-in) →
  `CurrentScope.grant!` / `current_scope:grant` (not raw
  `RoleAssignment.create!`) → `/current_scope`. Member starts empty.
- **Limitations page (#115).** Canonical SSR-first stance and intentional
  residuals (A5/A2/A6, trusted model hook, report-mode model_invalid, opt-in
  tripwire, no cascade) in the README and
  [docs/site/limitations.md](docs/site/limitations.md).
- **Silent-security documentation (#27, #29, #36).** Root [UPGRADING.md](UPGRADING.md)
  leads with the 0.1→0.2 `sod_actions` default flip. SoD guide + README document
  collection actions in `sod_actions` as no-ops (bulk recipe), `full_access`
  holding break-glass bypass, and that advisory `allowed_to?` never consults
  the catalog.
- **A mis-declared `current_scope_parent` now fails the deploy instead of
  serving wrong rows (#139).** BREAKING for one narrow, already-broken shape:
  a chain declared on a `belongs_to` with a custom `primary_key:`.

  The check is not new — `ParentChain.validate_declarations!` has always refused
  that shape. What changed is when it runs. It ran only from `to_prepare`, which
  railties executes **before** `:eager_load!`, so it saw only models something
  else had already loaded; in production, close to none. It now also runs after
  eager loading, where the registry is complete for models that were eager-loaded.
  Development keeps the `to_prepare` pass, which re-runs on reload and grows
  coverage as classes load, but never guarantees a full pass when
  `config.eager_load` is off (or when declaring models sit outside eager-load
  paths). The new pass is gated on `eager_load` so it never autoloads reloadable
  constants during initialization.

  **Why a broken deploy is the right outcome:** unvalidated, both `scope_for`
  and the unloaded member walk key the parent on its primary key. That hides
  records the grant should reach AND returns / opens unrelated records whose
  foreign-key value collides with a granted parent's id — dense collisions with
  a numeric custom key. A subject sees records nobody granted them. See
  [UPGRADING.md](UPGRADING.md) for the fix.

### Security
- **A subject could inherit another subject's roles when primary keys are not
  integers (#151).** `subject_id` and `resource_id` were integer columns
  (`t.references`), so a UUID or other non-numeric primary key was cast by
  `String#to_i` on write. `"7f00aaaa-…"` and `"7f00bbbb-…"` both stored as `7`; a
  key beginning with a letter stored as `0`. Distinct records collapsed into one
  identity, and a subject held a role nobody granted them — `full_access`
  included. **This affects 0.2, 0.3 and 0.4 as published.** Those versions have
  been yanked, and **0.5.0 is the first safe release** (0.1.0 carried the same
  defect but was never published to RubyGems). Security advisory:
  [GHSA-944r-4v99-qqf7](https://github.com/davidteren/current_scope/security/advisories/GHSA-944r-4v99-qqf7)
  (CVE pending); remediation of the published versions is complete (#151, closed).

  Nothing surfaced it: the association still resolved (to the wrong record), the
  per-subject uniqueness index saw the collapsed value as a single subject, and no
  test failed. Reproduced before fixing, and the reproduction is pinned in
  `test/uuid_key_collision_test.rb`.

  **The columns are now `varchar(64)`, so integer, UUID and ULID keys are all
  stored whole.** This is support, not a guard: nothing is refused for being a
  UUID. Only a key that is not ONE value — composite, or absent — is refused,
  because it names no single record.

  **Upgrading requires the migration**, and a gem upgrade does not run one:

  ```bash
  bin/rails current_scope:install:migrations && bin/rails db:migrate
  ```

  The engine refuses to serve until it has run, because every code path behaves
  correctly against the schema it is given and the escalation would otherwise
  persist silently. Database, installer and `assets:` tasks are exempt so the
  repair and the asset build are not blocked; `db:seed` is not, because it runs
  host code. A database built from `schema.rb` cannot be repaired by
  `db:migrate` (schema load stamps every version as applied), so
  `bin/rails current_scope:repair_schema` applies the shape idempotently.

  Details that each closed a way the collision survived widening:
  - **MySQL gets a binary collation** — `utf8mb4_0900_bin` where the server has
    it, else `utf8mb4_bin`. The default is case AND accent insensitive, so
    `"ABC"` and `"abc"` — or `"jose"` and `"josé"` — still compared equal. The
    `0900` variant is also `NO PAD`, so `"abc"` and `"abc "` stay distinct. A
    primary key is an identifier, not prose.
  - **An id that is not a legal key for the model it names is refused**, on
    write and on read. The columns take any string now, so a grant could name a
    bigint-keyed model with a UUID — and the read path would cast it back to a
    different record's id, which is the same collapse one layer along.
  - **Grant ids read back as `String` for every host**, integer keys included:
    `grant.subject_id == user.id` is now `false`. Compare `.to_s` on both sides.
  - **Keys longer than 64 characters are rejected, not truncated**, checked in
    Ruby so every adapter fails the same way instead of depending on `sql_mode`.
  - **The suite now runs on SQLite, PostgreSQL and MySQL** (`bin/db`, plus a CI
    matrix job). A SQLite-only suite is how this reached three releases: it
    coerces the string/integer comparisons the other two refuse. The first
    PostgreSQL run produced 106 errors.

  **Rows written before the upgrade are not repaired** — once `"7f00aaaa-…"` was
  stored as `7`, the original value is gone. After migrating they match nobody, so
  they fail closed (access lost, not gained) and show as inert grants. See
  [UPGRADING.md](UPGRADING.md) for the audit query and the re-grant step.

  `scope_for` is now **eager**: it reads the granted ids when the relation is
  built rather than leaving a subquery, because comparing a string column to a
  bigint one is what PostgreSQL refuses. The returned relation is still lazy and
  chainable, but it is a snapshot of the grants at call time.

### Fixed
- **The "scoped `full_access` does not cascade" rule is now actually tested
  (#148).** No behavior changed; the guarantee was simply unguarded. `roles_ticking`
  excludes `full_access` roles precisely so one scoped grant on a parent cannot open
  every permission on every descendant, and deleting that exclusion left the entire
  suite green.

  Three tests looked like they covered it and none of them ran the exclusion, all for
  the same reason: `roles_ticking` filters on `permission_key` first, so a role that
  ticks nothing (or ticks a *different* key from the one under test) is dropped one
  step earlier and the test passes either way. The shape the exclusion actually stops
  is a role that is `full_access` **and** ticks the key being checked, which the
  resolver names as real since a host can tick grid cells and then flip the flag.

  Now pinned at all three places where the exclusion decides an allow or a deny: the
  parent-chain gate (`parent_scoped_grant_test.rb`), the parent-chain list
  (`parent_scope_for_test.rb`), and the record-less write gate
  (`collection_scope_gate_test.rb`, where a `full_access` role ticking `reports#create`
  would otherwise open `#create` across the type). The same deletion now fails three
  tests instead of none. A fourth consumer, `record_less_denied_for_unknown_type?`,
  only labels a denial rather than deciding one, and stays unpinned.

  Each parent-chain test carries a positive control, because the denial also holds when
  the ancestor arm is dead — "excluded" and "the chain never resolved" are
  indistinguishable from the assertion alone. The invariant is now recorded in the
  do-not-regress list in
  [docs/internal/READINESS-AUDIT.md](docs/internal/READINESS-AUDIT.md), which AGENTS.md
  hard rule 3 points at, together with the `collection_read_actions` residual that
  makes it non-absolute.

- **Coverage measured only `app/` and reported the whole engine as dead code
  (#114 follow-up).** SimpleCov started from `test/test_helper.rb`, but the
  test command's own prepare step boots the dummy app, and with it the engine,
  before the runner requires a single test file. Ruby's `Coverage` only instruments files
  loaded after it starts, so every file under `lib/` recorded zero covered lines
  while `cover "{app,lib}/**/*.rb"` kept counting them in the total. Files the
  suite plainly exercises, `resolver.rb` and `guard.rb` among them, read 0%.

  The reported number therefore fell as the engine grew rather than as tests
  lapsed: 44.49% at the #124 baseline, 34.95% once #108, #133, #134 and #139
  added files to `lib/`. For an authorization gem it was measuring the wrong
  half — the mounted management UI, not the decision path.

  The bootstrap moved to `test/coverage_setup.rb`, required from `bin/rails`
  before the engine loads and still from `test_helper.rb` for runners that load
  a test file directly (`require_relative` makes the second call a no-op). Not
  named `coverage.rb`: `ruby -Itest` puts that directory on the load path, and
  SimpleCov's own `require "coverage"` would then find it instead of the stdlib
  extension. `COVERAGE=0` still skips.

  The bootstrap **raises if it ever runs after the engine has loaded**, because
  nothing else would notice: the suite still passes and the number just quietly
  drops back. `bin/rails` matches railties' `t` alias as well as `test`, so
  `bin/rails t` measures the same as `bin/rails test`. `test/coverage_setup_test.rb`
  pins both require sites, pins which files the run actually measures, and proves
  the guard fires; deleting either `require_relative`, or narrowing `cover` back to
  `app/`, now turns the suite red instead of silently halving the number.

  **No test of the engine changed; only the measurement did.** True coverage is
  **97.40% line (1503 of 1543) and about 85% branch**, unit and system merged,
  against the 34.95% previously reported. Two kinds of line are out of the
  denominator because no test could ever reach them: the install generator's
  `templates/`, which is copied into a host app rather than executed here, and
  `version.rb`, which `bundler/setup` loads through the gemspec before any
  bootstrap could start. No `minimum_coverage` floor yet — that needs a decision
  about CI failure behavior and is tracked in (#146).

- **Boot could crash validating a declared parent chain (#108, found while
  building #133).** `ParentChain.validate_declarations!` iterated its registry
  of declaring models while resolving each reflection, and resolving one
  autoloads the parent model — whose own `current_scope_parent` declaration
  registers it, mutating the collection mid-walk. Ruby answers that with
  `RuntimeError: can't add a new key into hash during iteration`, raised out of
  `to_prepare`, so any host whose declared chain points at another declaring
  model could crash on boot or on a development reload. It now walks a snapshot;
  a model that registers mid-walk is validated on the next pass.

## [0.4.0] - 2026-07-23

Solid-solution Phase 1 plus the adoption surface: denial ergonomics, the
security checklist, a real documentation site, and the complete
Pundit / CanCanCan / Action Policy migration toolkit. No intended host API
break. **Upgrade-visible:** a `sod_bypass_permission` listed in
`sod_actions` now **fails at boot** (#40) instead of 500ing on the first
real bypass — a colliding config that previously deployed silently will
refuse to start until fixed.

### Added
- **Documentation site with committed source (#98, #33).** The Pages site is
  now a real doc site built from [docs/site/](docs/site/) by GitHub Actions:
  quickstart, concepts, the **separation-of-duties guide** (opt-in stated
  loudly, verification recipe, break-glass honesty), the security checklist
  (generated from its single in-repo source), a config reference, upgrading
  notes, copy-paste **prompts for AI agents**, and `llms.txt`. The landing
  page's quickstart gained the sessions gate-skip step it was missing
  (following it verbatim used to lock sign-in).
- **Migration toolkit for Pundit, CanCanCan, and Action Policy (#45).** The
  `current-scope-migrate` Claude Code skill
  ([.claude/skills/current-scope-migrate/](.claude/skills/current-scope-migrate/),
  ships in the repo, not the gem): deterministic AST rule inventories
  (fail-closed — only provable shapes are auto-classified), a per-system
  **parity harness** that diffs old vs new answers over an exemplar matrix,
  reviewable role-backfill migrations (enum column or rolify), and a
  proof-gated call-site rewriter behind an explicit `--write`. Three
  self-test suites run in this repo's CI.
- **Denial ergonomics (#39).** `AccessDenied` exposes `#permission`, `#record`,
  and `#subject` (in addition to `#reason`) so branded 403 pages and trackers
  need not parse `#message`. The engine registers
  `CurrentScope::AccessDenied → :forbidden` in `rescue_responses` so an
  escaped denial is HTTP 403, not 500. Rescued denials log
  `[CurrentScope] denied controller#action (reason) → 403`.
- **Security & production checklist (#32).** New
  [docs/SECURITY-CHECKLIST.md](docs/SECURITY-CHECKLIST.md): excluded + skip =
  ungated consequence, 403/404 record-existence oracle + opt-in mitigation,
  foot-gun index, and a going-to-production tick list. The
  `ConfigurationError` for gating an excluded controller (and the
  `excluded_controllers` comments) now name the BYO-auth consequence.

### Fixed
- **Orphaned scoped grants labeled inert in the console (#90).** Deleted or
  unresolvable resources no longer render as live scoped access on Subjects
  and role Members — chips/rows show “unavailable — inert” with an inert badge
  and a Remove inert control. Collection reads already fail closed for these
  since #65 (`collection_read_actions` / empty list); the UI now matches that
  operator-visible truth (explicit non-list grants can still match a row in
  rare cases — see ROADMAP/resolver notes).
- **Report-mode SoD blind-spot 403 is diagnosed (#73).** Report mode still
  refuses to downgrade a `:no_grant` where the SoD veto never ran (fail-closed),
  but now logs a warning naming the cause/fix and records a distinct
  `access.sod_blind_spot` ledger event (never `access.would_deny` — granting
  will not clear the 403). `rails current_scope:report` lists these separately.
- **Boot-validate `sod_bypass_permission` ∉ `sod_actions` (#40).** The recursion
  guard previously only raised at decision time behind three break-glass
  preconditions — a colliding config could deploy clean and 500 on the first
  real self-approval bypass. `Configuration#validate!` now runs from
  `Engine` `after_initialize` (always, regardless of `allow_sod_bypass`); the
  resolver still raises via the same shared predicate for runtime-mutated
  config.
- **Audit ledger bootstrap + `request_id` (#30).** `CurrentScope.grant!` now
  records `org_role.assigned` / `org_role.changed` (self-attributed,
  `source: "bootstrap"`) when the org role actually changes; the rake task
  warns on replacing a different role; `Context` stamps `request.request_id`
  onto `Current.request_id` so UI ledger rows correlate with app logs.
  Docs no longer claim unqualified "every authorization change."
- **SoD nil-record nudge asks the resolver (#74).** No more private
  nil/`NO_RECORD` re-derivation — `sod_veto_skipped?` covers a hook that returns
  `params[:id]` (String). Inert-grant diagnostic DB errors are rescued so they
  cannot 500 a request.

## [0.3.1] - 2026-07-19

Post-`0.3.0` patch: silent-security footguns and management-console lockout
guards from the solid-solution worklist (PR #100). No intended host API break.

### Fixed
- **`config.sod_actions` normalizes symbols and freezes the list (#91).**
  Writing `[:approve]` used to leave SoD off silently because the resolver
  matches action-segment **strings**. The writer now maps symbols → strings,
  freezes the list, and raises on full keys / non-name elements — same honesty
  as `collection_read_actions=`.
- **`collection_read_actions=` rejects Hash / nested-array junk and warns on
  `destroy_all` / `update_all`.** A Hash coerced to a never-matching member
  silently restored pre-#65 semantics; bulk write names the docs cite as
  escalation examples now warn like `create`/`update`/`destroy`.
- **Last full-access console lockout guards.** Demoting or deleting a
  full-access role, or clearing/destroying an org-wide assignment, is refused
  when it would leave **zero full-access org holders**. Checks use holder
  semantics (not “any empty spare full_access role row”), run under
  transactional locks, and allow deleting **unassigned** full-access roles.
  Demotion only treats an **explicit** `full_access` param as demoting.
- **Role destroy cascade audit no longer 500s on orphaned polymorphic
  subjects/resources** — event targets resolve defensively, like the members
  page already did.
- **`full_access` toggle is recorded on role update audit events**
  (`full_access_from` / `full_access_to`).
- **`ambient_collection_model` is private** on the Permissions mixin (internal
  gate/view binding, not host API).

### Changed
- Management UI: role delete confirm names non-zero cascade holder counts and
  uses the danger button; scoped-picker labels associate with controls;
  subjects Set controls get subject-scoped `aria-label`s; lockout flashes
  include a recovery step.

## [0.3.0] - 2026-07-19

### Added
- **A scoped `full_access` role opens its type's collection reads, derived
  from the scoped list (#65).** "Owner of Report #7" no longer gets a 403 on
  the very index that would show Report #7. For actions in the new
  `config.collection_read_actions` (default `["index"]`; `[]` opts out and
  restores the previous semantics) the record-less gate asks `scope_for` —
  the same id-narrowed query the list renders from — so the gate opens
  exactly when the subject's list is non-empty and the two halves agree by
  construction. Every other record-less action is unchanged: an explicit tick
  opens it, `full_access` stays barred (a boolean, record-unbound check can
  never honor a wildcard safely — the #49 lesson, re-refuted on plan 029 and
  recorded on #65). SoD's record-less refusal still runs first. The list is
  **for list-narrowing reads only** — naming a mutating action in it hands
  scoped full_access holders that action type-wide, which is the escalation
  this design exists to prevent. Report-mode hosts will see fewer
  `access.would_deny` rows for scoped-full_access subjects: those checks are
  genuine allows now.

  **Upgrade-visible — who this changes:** two populations, one per direction.
  *Widened:* every subject holding a scoped `full_access` grant gains a
  working `#index` for their record's type on upgrade (this is the fix; set
  `config.collection_read_actions = []` to keep the old refusal). *Tightened:*
  a subject whose scoped grant — ticked or full_access — points at a record
  that is **absent from the model's default scope** now gets a 403 where they
  previously saw an empty page, because listed reads answer strictly from the
  live list. "Absent" means destroyed, but equally soft-deleted, archived, or
  filtered out by a multi-tenant `default_scope` — the list would not show
  the record, so the gate agrees. A new post-upgrade 403 on an index almost
  always means the granted record is gone from the subject's list; the grant
  row still shows in the console. The widening reaches the class form too:
  `allowed_to?(:index, Report)` in any view — no controller declaration
  involved, the class form carries its own type — now returns true for a
  scoped `full_access` holder of a `Report`, so a link hidden pre-upgrade
  renders after it. One more widened-label consequence: in
  report mode (`enforcement = :report`), a scoped full_access holder hitting
  a listed read on a controller with `current_scope_record = nil` but no
  `current_scope_model` is now denied `:model_undeclared` — a hard 403 even
  in report mode (which downgrades only `:no_grant`), where pre-upgrade the
  same request passed through. Declaring the model is the one-line fix, and
  the dev/test nudge names it.
- **Scoped grants open a collection gate only for the type the controller
  declares (#50).** A collection action (`#index`, `#create`, a bulk key) names
  no record, so the gate could not tell which *type* it was deciding about — a
  scoped grant of any type opened every record-less gate. On `#index` that read
  as a cosmetic empty list, but on `#create` it was a live escalation: a subject
  scoped on a `Report` could create `Document`s, holding no grant on them.

  A controller now declares the type its collection actions list:

  ```ruby
  class ProjectsController < ApplicationController
    private
    # A collection-only controller declares both: current_scope_record = nil
    # says "no record here" (so a scoped grant can open the gate), and
    # current_scope_model names the type it lists. Declaring the model without
    # the record hook leaves it inert.
    def current_scope_record = nil
    def current_scope_model = Project
  end
  ```

  The record-less gate binds the scoped grant to that type (normalized through
  `base_class`, matching `scope_for`), and **fails closed when no type is
  declared**. `allowed_to?(:index)` in that controller's own views resolves the
  same type, so the view never disagrees with the gate.

  **Upgrade-visible — who this changes:** a **scoped-only** subject reaching a
  collection action on a controller that has **not** declared
  `current_scope_model` now gets a 403 where they previously reached the action
  (and, for `#create`, previously created records off an unrelated grant). The
  denial carries `X-Current-Scope-Reason: model_undeclared` and — in dev/test —
  a log line naming the one-line fix (`config.warn_on_undeclared_collection_model`,
  on by default in dev/test). Org-wide grants, `full_access`, and every
  per-record decision are unchanged. This ships in the same release as the
  record-less gate itself (#19), so there is no released version with the old
  unbound behavior to regress from.

  Not closed by the type bind itself, by design: a type-bound boolean cannot
  make `full_access` safe. The #65 entry above closes the read side in this
  same release by deriving those gates from the scoped list instead. And a
  scoped grant within one type still opens that type's `#create`,
  exactly as an org-wide grant of the key does — including **across STI
  siblings of one base class**: a grant on an `Invoice` opens a
  `CreditNote#create` gate, because both normalize to their `Document` base
  class and this branch answers with a boolean, not records (the list side has
  STI's own type predicate to narrow; `#create` has no list side). Cross-*base
  class* is closed; within one base class the collapse is the accepted ceiling.
- **The ungated surface is detectable — grid badge, a rake task, and a
  production tripwire posture (#62).** `skip_before_action :current_scope_check!`
  inherits into every subclass and fails open; it used to do so invisibly,
  with the permission grid still rendering those actions as grantable. Now:
  - the role editor badges any controller **provably** ungated ("gate not
    run") — bare skip, inherited skip, or `Guard` never included. The badge is
    proof-only: a conditional skip (`only:`/`except:`) is unprovable statically
    and renders unmarked (the grid's hint says so; #75 tracks a static third
    state). A marked row's cells stay tickable — marking is not disabling —
    and on a marked row carrying an injected `bypass_sod` cell the badge's
    claim visibly excludes it: break-glass is honored by whatever gated
    controller decides SoD on the record, so that one cell is live anyway.
  - `bin/rails current_scope:ungated` prints the same static inventory as a
    command — no mixin, no deploy, no traffic — and states its own limit,
    routing conditional skips to the tripwire. One asymmetry with the grid: a
    controller whose body raises `NameError` while loading renders as an
    explicit "could not inspect" row in the grid (other load errors still
    surface as errors), while the task aborts with that error — its
    output makes proof claims a partial walk can't honor, so fix the broken
    controller and re-run.
  - `config.gating_tripwire = :raise | :warn` gives `GatingTripwire` a
    posture: `:raise` (the dev/test default) keeps today's behavior; `:warn`
    (the default outside dev/test) logs each ungated `controller#action` once
    per process instead of raising, so a real app can inventory its ungated
    surface from production traffic.

  The fail-open itself stays open, deliberately — this is detection, not
  prevention. A host that skips on purpose keeps its authorization behavior
  unchanged and adopts no new API; what a deliberate skip DOES pick up is the
  detection surface itself — a bare or inherited skip's grid rows are badged
  and the task lists them (a conditional skip stays unmarked: unprovable
  statically, caught by `:warn`), and
  a host that also opted into the tripwire marks intentional public actions
  with the existing `current_scope_skip_tripwire!` so `:warn` doesn't
  inventory them. The declared-skip macro that renders intent instead of a
  warning is #76.

### Changed
- **Management-UI route rename — upgrade-breaking for hosts that call it
  programmatically** *(errata: added after the v0.3.0 tag; the change shipped
  in it, via #85's convention cleanup)*: org-wide role assignment is now
  `resources :role_assignments` (plural, `create` + `destroy`) instead of
  `resource :role_assignment, only: :create` plus a hand-rolled delete. A host
  that POSTs `/current_scope/role_assignment` (singular) gets a 404 on
  upgrade — POST to `/current_scope/role_assignments`. Route helpers moved
  too: `current_scope.role_assignment_path` (create) is now
  `role_assignments_path`, and `remove_role_assignment_path` (destroy) is now
  `role_assignment_path(id)`. The engine's own UI is unaffected; this bites
  only direct path/helper callers (both gem test-scenario hosts that did so
  hit the 404 immediately).
- **`GatingTripwire` in production now defaults to `:warn` — and that is a
  disclosure change, named plainly:** the old unconditional raise meant an
  ungated action's response was withheld by the 500 (its side effects already
  ran; only the body was discarded). Under `:warn`, **ungated responses that
  were previously withheld are now served to the caller, with a log line.**
  Dev/test behavior is unchanged (`:raise`). A host that included the mixin in
  production and relies on that 500 as a backstop must pin
  `config.gating_tripwire = :raise`.
- **Report-only enforcement — retrofit an existing app without breaking it.**
  Adding a fail-closed gate to an app that already has users and controllers has
  been all-or-nothing: the moment you mount it, everything is denied, because no
  grants exist yet. Your suite goes red, your users get 403s, and the only way to
  find out what you needed to grant was to break things and read the wreckage.
  That is a bad first day with an authorization library, and it is the reason a
  retrofit gets abandoned rather than finished.

  Report mode inverts that. Set `config.enforcement = :report` and the gate logs
  what it *would* have denied and lets the request through, recording each one to
  the ledger as `access.would_deny` with the subject and the permission they were
  missing:

  ```bash
  bin/rails current_scope:report
  ```
  ```
  Would-be denials — grant these to stop them (most-denied first):

    Ada Lovelace — currently Member
        412x  reports#index
         38x  reports#export

  Total: 450 would-be denials across 1 subject(s).
  ```

  That is the work, in the shape of the role grid you need to build: seed the
  roles it names, watch it empty out, then set `config.enforcement = :enforce`. Every step is one line back, and you learn
  what to grant before anyone is refused rather than after. The install generator
  now says this up front when it detects an app that already has controllers,
  which is when it matters.

  Report mode is an **adoption ramp, not an off switch**, and it is not a way to
  run in production — enabling it there logs a loud boot warning saying so. It
  relaxes exactly one denial: "nobody has granted this yet". A separation-of-duties
  veto still refuses (relaxing it would let an initiator actually approve their own
  record — a fraud action executed, not a role gap surfaced), and so does an SoD
  action the veto couldn't run on at all, because a refusal that reads `no_grant`
  there means *nobody asked the veto*, not *the veto approved*. The management
  console, where grants are made, is never opened by it. `:enforce` remains the
  default and is unchanged. (#37)

- **Three silent failure modes now tell on themselves in development.** Each of
  these is silent *in the bad direction* — what went wrong looks exactly like what
  going right looks like — and each one cost real debugging time in the scenario
  apps:

  - **`config.warn_on_nil_sod_record`** (existed, **now on by default in
    dev/test**): the separation-of-duties veto was *skipped*, because an SoD member
    action's `current_scope_record` returned nil. The request was allowed, and a
    veto that never ran looks exactly like a veto that passed. This has worked
    correctly since v0.1 but shipped **off**, so the teams who needed it never
    learned it existed — which is the actual bug being fixed here.
  - **`config.warn_on_inert_scoped_grant`** (new): denied `no_grant` while the
    subject holds a scoped grant that *would* have satisfied it, on a controller
    that declares no `current_scope_record`. That's a member action that forgot its
    hook. It fails closed — correctly — but the 403 is byte-identical to "you were
    never granted this", so you go and audit the grants, which are fine, instead of
    the controller, which isn't.
  - **`config.warn_on_cross_controller_derivation`** (new): short-form
    `allowed_to?(:show, record)` derived a different key than the gate on the
    current controller enforces — the documented namespaced-controller foot-gun. If
    you meant this controller's gate, the view and the gate silently disagree, and
    the symptom (a link that 403s, or one that's hidden but would work) shows up
    nowhere near the cause. This one is a **hint, not an accusation**: asking about
    a different resource than the controller handles derives a different key too,
    and that's correct. Nothing at the call site tells the two apart, so it warns
    **once per site** and names both readings rather than claiming a bug it can't
    prove.

  All three are **log-only**: no decision, exception, header, or audit row changes
  in any environment. All three default **on in development and test, off in
  production** (and off entirely without Rails). The default is the point — these
  catch mistakes you make while *writing* the app, which is exactly when dev/test is
  where you are. Override any of them either way. (#41)

### Fixed
- **`config.collection_read_actions` rejects elements that aren't action
  names.** `Array({ index: true })` is `[[:index, true]]`, and its `.to_s` is
  a member that can never match an action — so a Hash or nested array froze
  as a silently-inert list, replacing the `["index"]` default and restoring
  the pre-#65 record-less semantics with no signal. Fails closed (never
  widens), but a silently-disabled security knob is the exact failure the
  writer's validations exist to prevent. Non-String/Symbol elements now raise
  `ConfigurationError` naming the offending value, like the keyed-member
  raise. (0.3.0 release-gate finding)
- **A mis-declared `current_scope_model` now says so.** A declared hook
  returning something unusable — `"Report"` for `Report`, an instance, an
  abstract class — was refused by the shape guard (correctly, fail-closed)
  but denied as plain `:no_grant`: byte-identical to "never granted", pointing
  nowhere near the bad declaration. That deny is now labelled
  `:model_invalid` on `X-Current-Scope-Reason` (when the subject holds a
  scoped grant satisfying the key — the same honesty condition as
  `:model_undeclared`), and the dev/test nudge (same
  `warn_on_undeclared_collection_model` flag) names the value the hook
  returned and the fix. Label-only under `:enforce` — and, like
  `:model_undeclared` above, a **report-mode** host with a mis-declared model
  now gets a hard 403 where the same request previously passed through as an
  observed `:no_grant` (report mode downgrades only `:no_grant`; a
  misconfigured collection gate is not that). (0.3.0 release-gate finding)
- **The management UI's 403 now says why.** Opening the console without a
  full-access role returned a bare, bodyless `403` with no
  `X-Current-Scope-Reason` — the one denial in the gem that sat outside the
  `AccessDenied` machinery, because `require_full_access!` rendered its own
  `head :forbidden` instead of raising. "Why can't I open the management UI?" is
  the first question an admin asks, and the answer was a blank page. It now
  raises like every other denial, so it carries `X-Current-Scope-Reason:
  not_full_access` and renders a short page explaining that the console is where
  permissions are granted and therefore only full-access subjects enter. (#23)

  **Who is denied has not changed** — the `full_access?` check is byte-for-byte
  what it was. Only the shape of the refusal changed.

  **Host denials are untouched:** a denial raised through `Guard` /
  `MutationGuard` is still a bodyless `head :forbidden`. The rendered page is
  the engine UI's alone — the shared denial path runs inside *your* controllers,
  and pushing an engine-shaped body into an app's own response contract (with no
  layout or view to render it in) would be a surprise nobody asked for. The
  reason header is written in exactly one place, so no denial can forget it.

- `AccessDenied#reason` gained `:not_full_access`, and the vocabulary
  (`:sod_veto`, `:no_grant`, `:impersonation_gate`, `:not_full_access`) is now
  documented in the README rather than only in a code comment.
- **The break-glass `bypass_sod` permission is now grantable through the role
  grid**, as the README and `configuration.rb` have always claimed. It isn't a
  routable action, so a route-derived catalog could never contain it: no cell
  existed to tick anywhere in the UI, and a hand-crafted grant was dropped by
  `Role#permission_keys=`. The documented "trusted admin may self-approve" role
  was therefore unbuildable with the shipped tooling — break-glass was reachable
  only through `full_access` (which grants it implicitly along with everything
  else, defeating the point of a *scoped* trusted approver) or a console
  `RolePermission` insert. The catalog now injects the virtual key, which is the
  one seam the grid, the role setter and the Guard all read, so the cell renders
  and the save sticks with no special case in any of them. (#21)

  The column appears only where it can mean something: `config.allow_sod_bypass`
  on, **and** a controller that routes an action listed in `config.sod_actions`.
  With break-glass off (the default) the catalog is byte-for-byte the routed set
  — no new columns, and the key is rejected if assigned. Nothing about the
  resolver, the decision order, or the three live conditions for a bypass
  changed; the permission was always checked correctly, it just couldn't be
  granted.

  The key is named after the **resource**, not the controller path, because that
  is what the resolver looks up (it derives the bypass key from the record's
  `route_key`). So `Admin::ReportsController#approve` contributes
  `reports#bypass_sod` — the key that actually works — and a namespace-only
  resource shows its bypass cell on a `reports` row that no controller routes.

  Known limit: a controller named differently from the records it acts on (an
  `approvals` controller approving `Invoice`s) still contributes an inert
  `approvals#bypass_sod` while the live `invoices#bypass_sod` is not injected.
  Closing that needs to know the SoD-gated model, which the catalog
  deliberately does not load. Tracked in the issue's OQ-2.

  `config.allow_sod_bypass = true` with a blank `config.sod_bypass_permission`
  now raises `ConfigurationError` rather than injecting a malformed key: a
  permission nobody can hold means break-glass is inert while the host believes
  it is armed.

### Changed
- **`Role#permission_keys=` now rejects unknown keys loudly instead of dropping
  them.** A key that isn't in the route-derived catalog makes the role invalid —
  `save` returns `false`, `save!`/`update!` raise `ActiveRecord::RecordInvalid`,
  and `errors[:permission_keys]` names the offending keys. Previously they were
  silently discarded at assignment: a typo (`reports#aprove`), a programmatic
  grant of an unrouted key, or a `db/seeds.rb` granting the never-routed
  break-glass permission all saved cleanly and produced a role that looked
  correct and denied at runtime for no visible reason. Nothing outside the
  catalog was ever persisted, and still isn't — only the signal changed, from
  silence to an error. (#20)

  **Upgrade-visible, and only for programmatic callers.** If you assign literal
  key sets that contain stale keys (from controllers you have since removed),
  those call sites now fail instead of self-cleaning. Name the intent:

  ```ruby
  role.assign_permission_keys(keys, scrub: true)   # drops non-catalog keys, no error
  role.permission_keys_change[:rejected]           # => ["gone#index"]
  ```

  `scrub:` is not reachable through `permission_keys=`, so mass assignment and
  strong params always take the strict path. The management UI is unaffected —
  its grid only ever submits catalog keys, and a role holding a stale key still
  has it cleaned up transparently on save.

  **If a seed grants the break-glass permission, it will now raise — and that is
  the point.** `config.sod_bypass_permission` (default `"bypass_sod"`) is a bare
  action name, not a `controller#action` key, so no route can ever produce it
  and it was silently dropped every time: the role saved cleanly and could never
  bypass. The failure is telling you that grant has never worked. Do **not**
  paper over it with `scrub: true` — that just restores the silent version.
  Making break-glass grantable is tracked in #21.

- `permission_keys_change` gained a `:rejected` array alongside `:added` /
  `:removed`, so a caller that opted into scrubbing can still log what went.

### Fixed
- **Scoped grants now open a record-less gate** — a subject holding only scoped
  grants was 403'd on every collection action (`#index` and friends), because
  the gate asks the resolver with `record: nil` and the scoped branch required a
  persisted record. The only way in was an org-wide grant, which makes
  `scope_for` return *every* record — so no grant combination produced the
  scoped index the README advertises. A record-less target (nil, or a Class for
  `allowed_to?(:index, Model)`) is now allowed when the subject holds any scoped
  grant whose role ticks the key; `scope_for` is unchanged and still narrows the
  list. Fixed at the shared resolver seam, so the gate and the `allowed_to?`
  view helper agree. (#19)

  **⚠ Upgrade-visible — check your index actions before upgrading.** A scoped
  grant whose role ticks a collection key now opens that gate where it
  previously 403'd. **If a gated `#index` does not call `scope_for`, subjects
  who used to hit a 403 wall will now reach it and see every record the action
  queries.** `scope_for` is guidance, not an enforced constraint, so the engine
  cannot narrow a list the host renders with `Model.all` — the gate only decides
  *whether* the action runs. Before upgrading, for every collection action whose
  key a scoped role ticks, confirm the action scopes its own query. This is the
  one way the fix can expose data rather than merely admit a user.

  Otherwise it grants nothing a role author did not tick, and no decision on a
  persisted record changes — a grant on X still confers nothing on Y, and the
  SoD veto, full_access and org-role paths are untouched. Two further notes:
  the rule is uniform across record-less targets, so a scoped role ticking
  `create` or a bulk key opens those gates too, exactly as an org-wide grant of
  that key already does; and a **scoped `full_access` role does not open
  record-less gates at all** — it satisfies every key, so honoring it here would
  turn one scoped grant into a pass on every `#index` and `#create` in the app.
  It keeps its full authority over its own record.

  Two things this path deliberately will **not** do, both fail-closed: it never
  opens a **separation-of-duties action** (a four-eyes action is
  record-targeted by definition, so a record-less one has no record for the veto
  to measure — it is denied rather than granted with the veto skipped); and it
  never fires on a controller that **declares no `current_scope_record` hook**.
  A hook returning nil is the host saying "this action has no record", and the
  gate trusts it; no hook says nothing, and reading silence as "collection
  action" would let a controller that forgot the hook hand a scoped subject
  every record of its type. Both keep the pre-0.2.x behavior for misconfigured
  hosts.

  **If a collection-only controller has no hook and you want its gate to honor
  scoped grants, declare one:** `def current_scope_record = nil`. Nothing that
  worked before stops working — without a hook, scoped grants could never open a
  collection gate anyway — but this is the line that opts in.

## [0.2.0] - 2026-07-14

### Added
- Impersonation / act-as: `Current` carries the real `actor` alongside the
  effective `user`; `config.actor_method`, `config.sod_identity`, and a
  read-only-while-impersonating `MutationGuard`.
- Append-only audit ledger (`current_scope_events`) with a read-only index.
- `scope_for(Model)` — the list-side complement to `allowed_to?`, from the same
  grants (STI-aware: normalizes to `base_class`).
- Scoped-role picker (Role → Subject → Type → Record) + `CurrentScope::Scopeable`,
  with an opt-in `current_scope_searchable_scope` hook for indexed search.
- Host test helpers `grant_role!` / `grant_scoped_role!` (survive the request cycle).
- `CurrentScope::GatingTripwire` — opt-in mixin that catches ungated controllers.
- `CurrentScope.grant!` + `current_scope:grant` rake task to bootstrap the first admin.
- Pagination for the subjects page and events index.

### Changed
- **Separation of duties is opt-in**: `config.sod_actions` now defaults to `[]`.
- **Declared Rails floor is `>= 8.1`** (the management UI relies on `params.expect`
  array semantics introduced in 8.1); the CI test job exercises it.
- `config.audit` is tri-state: `false | true | :strict`.

### Security
- Production guardrail: `config.allow_mutations_while_impersonating = true` raises
  at boot in production unless `CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS`
  is set.
- The impersonation-boundary API raises when `config.actor_method` is unset,
  instead of silently running with inert act-as security.

### Fixed
- `with_current_user` restores the ambient context correctly across the whole
  `>= 8.1` floor (was version-fragile).

## [0.1.0] - 2026-07-10

### Added
- Initial engine: fail-closed resolver (SoD veto → full_access → org role →
  scoped role → deny), route-derived permission catalog, roles as editable data,
  one org-wide role per subject, per-record scoped roles, a loud separation-of-
  duties veto, an ambient authorization context (`ActiveSupport::CurrentAttributes`)
  so `allowed_to?` works identically in controllers, views, and ViewComponents,
  the mounted management UI, and the `current_scope:install` generator.

[Unreleased]: https://github.com/davidteren/current_scope/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/davidteren/current_scope/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/davidteren/current_scope/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/davidteren/current_scope/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/davidteren/current_scope/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/davidteren/current_scope/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/davidteren/current_scope/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/davidteren/current_scope/releases/tag/v0.1.0
