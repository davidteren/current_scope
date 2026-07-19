# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/davidteren/current_scope/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/davidteren/current_scope/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/davidteren/current_scope/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/davidteren/current_scope/releases/tag/v0.1.0
