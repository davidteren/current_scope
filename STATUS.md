# STATUS

> Last updated: 2026-07-16
>
> **If you are a fresh session asked to audit this work, start at
> [Verification brief](#verification-brief--for-a-fresh-session).**
> It names what to distrust and why, and it is more useful than reading this
> file top-to-bottom.

## What this is

**CurrentScope** — a mountable Rails engine for authorization: permissions
auto-derived from `controller#action` routes, roles as editable data, per-record
scoped roles, an optional separation-of-duties (four-eyes) veto, impersonation/act-as, an
append-only audit ledger, and an ambient authorization context
(`ActiveSupport::CurrentAttributes`) so `allowed_to?` works identically in
controllers, views, and ViewComponents.

- Design concept: [resources/DESIGN.md](resources/DESIGN.md) (captured under the
  placeholder name "Grantwork")
- Research basis: [docs/RESEARCH.md](docs/RESEARCH.md) — palkan / Evil Martians
  on CurrentAttributes vs dry-effects vs explicit passing, Action Policy ideas
- Usage: [README.md](README.md)
- **What's next / gaps / proposals: [docs/ROADMAP.md](docs/ROADMAP.md)**
- Readiness audit: [docs/READINESS-AUDIT.md](docs/READINESS-AUDIT.md) — **complete
  (A1–A13, PR #5); historical, not a worklist.** Kept for its reasoning and for the
  "Verified holding — DO NOT regress" invariants. Current work is in the
  [issues](https://github.com/davidteren/current_scope/issues) + `docs/plans/`
- Showcase app: **[davidteren/current_scope_showcase](https://github.com/davidteren/current_scope_showcase)**
  (own repo; consumes the published gem — no longer vendored)

Version `0.2.0`, **published to RubyGems** (tag `v0.2.0`) — the showcase consumes
it as an ordinary `gem "current_scope"`. Not production-ready; see the README
banner.

## Done (all committed on `main`)

### v0.1 core (engine at repo root)

- [x] Resolver with fixed decision order: SoD veto (or an audited break-glass
      bypass) → full_access → org-wide role → scoped role → scoped role on a
      record-less target → default-deny (`lib/current_scope/resolver.rb`)
- [x] PermissionCatalog derived from routes — no permissions table; new
      controllers appear in the grid automatically
- [x] Models: `Role`, `RolePermission`, `RoleAssignment` (one org-wide role per
      subject), `ScopedRoleAssignment` (polymorphic subject + resource)
- [x] Ambient context: `CurrentScope::Current` + `Context` / `Guard` /
      `Permissions` mixins; `TestHelpers#with_current_user`
- [x] Management UI (mounted engine): role editor with controller×action
      permission grid, full-access toggle, subjects page, org-wide + scoped
      assignment; entry restricted to full-access subjects
- [x] `current_scope:install` generator + `current_scope:install:migrations`
- [x] Gem packages cleanly (`gem build`; showcase excluded)

### Hardening (29-agent multi-lens review, 21 confirmed findings fixed)

- [x] SoD fails **loud, not open**: missing `current_scope_initiator` on a
      record hit by an SoD action raises `ConfigurationError` (nil exempts)
- [x] `?id=` query strings can't smuggle a record into collection actions
      (hooks key off `request.path_parameters`; regression-tested)
- [x] `allowed_to?` always agrees with the gate under namespaced controllers
- [x] Guard raises on gating a catalog-excluded controller; Context raises on a
      missing `user_method` (misconfiguration ≠ silent 403)
- [x] Management UI refuses to delete the last full-access role

### Buildout — PR #3 (extends v0.1 behind config, core model unchanged)

- [x] **Impersonation / act-as**: `CurrentScope::Current` carries `actor` (real)
      alongside `user` (effective subject); permissions resolve against the
      subject, attribution reads the actor. `config.actor_method`;
      `config.sod_identity = :either` (veto fires if either identity initiated
      the record — closes the impersonation self-approval path). Read-only-
      while-impersonating gate (`MutationGuard`) with documented per-controller
      skips; `AccessDenied#reason` (`:sod_veto` / `:no_grant` /
      `:impersonation_gate`) surfaced on `X-Current-Scope-Reason`.
- [x] **Audit event ledger**: append-only `current_scope_events` table (actor +
      subject + target GlobalID strings, denormalized `target_label`, no
      `updated_at`, `readonly?` once persisted). Transactional recording at
      controller mutation sites; read-only events index. Graceful degrade
      (warn-once, no-op) when the table hasn't been migrated; `config.audit`.
- [x] **`scope_for(Model)`**: list-side complement to `allowed_to?` — derives
      the visible relation from the same roles/permissions/scoped grants the
      gate reads (gate/list agreement by construction). Fail-closed, flat.
- [x] **Scoped-role picker** + `CurrentScope::Scopeable` opt-in registry:
      Role → Subject → Resource-type → Record UX (GlobalID stays storage form).

### This session (2026-07-12)

- [x] **SoD is now opt-in**: `config.sod_actions` defaults to `[]` (was
      `%w[approve]`). The engine's baseline is scoped RBAC; enable four-eyes by
      listing actions. `[]` makes the veto a no-op (resolver collapses to
      full_access → org → scoped → deny; no model needs
      `current_scope_initiator`). README + generator reframed as opt-in. (The
      showcase now opts in explicitly.)
- [x] **Production guardrail**: `config.allow_mutations_while_impersonating =
      true` raises at boot in `Rails.env.production` unless
      `ENV["CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS"]` is set —
      privilege-escalation/audit risk fails loudly instead of running silently
      insecure. dev/test/staging unaffected; `false` never raises.
      (`test/configuration_test.rb`)

### Readiness remediation — A1–A13 (branch `feat/readiness-p0`, PR #5)

Worked `docs/READINESS-AUDIT.md` end to end (plan:
`docs/plans/2026-07-12-002-feat-engine-readiness-remediation-plan.md`), P0→P4,
all test-first:

- [x] **P0** — gemspec Rails floor corrected (A1); loud `actor_method` check at
      the impersonation-boundary API (A2); host test helpers `grant_role!` /
      `grant_scoped_role!` (A3).
- [x] **P1** — audit tri-state `config.audit = :strict` (A6); `GatingTripwire`
      mixin for ungated controllers (A4); SoD nil-record characterization +
      opt-in nudge (A5).
- [x] **P2** — `scope_for` STI `base_class` fix (A7); namespaced key-drift docs
      (A8); **Rails floor proven → raised to `>= 8.1`** (A9; `params.expect`
      array semantics need 8.1). Also fixed `with_current_user` restore + test
      isolation.
- [x] **P3** — `config.audit` discoverable (A10); `current_scope:grant` rake
      task (A11); subjects/events pagination (A12·1); picker search hook (A12·2).
- [x] **P4** — CHANGELOG + gemspec metadata; `gem build` warning-clean (A13).

**Engine suite: 181 runs green; RuboCop omakase clean; `gem build` clean.**
PR #5 merged to `main`.

### Admin dashboard UI + role/subject UX — branch `feat/admin-dashboard-ui`, PR #6 (OPEN, not merged)

A large management-UI pass on top of readiness. All `app/`-side (hot-reloads in a
host), self-contained (no web fonts / no build / CSP-safe), opinionated but
overridable. **201 runs green, RuboCop clean.**

- [x] **Light/dark admin dashboard** — sidebar + topbar shell, cobalt accent,
      token theming (`prefers-color-scheme` + a persisted `current_scope_theme` cookie,
      server-rendered → no flash; toggle is a served-asset handler).
- [x] **Permission grid → absolute CRUD matrix** — fixed columns, blank cells
      where a controller doesn't route a column; RESTful 7 fold into
      read/create/update/destroy by default (`config.permission_grid_groups`,
      nil = raw). `CurrentScope::PermissionGrid` PORO expands `controller:group`
      tokens on a separate param channel; raw `permission_keys` still works. A
      ticked cell glows; per-row master toggle.
- [x] **Role descriptions** — `description` column (new migration) + form + index.
- [x] **Subject identity** — `config.subject_label` (Symbol/Proc); default is
      people-first: email → email_address → name → first+last → id.
- [x] **Subjects filter** — client-side, framework-free vanilla JS.
- [x] **Bulk assignment** — multi-select subjects → **bulk scoped role** (picker
      accepts `subject_gids[]`) **and bulk org-wide role** (blank clears).
- [x] **Discoverable scoped revoke** — labeled, confirm-guarded chip control.

**Reload gotcha (host running the engine as a path gem):** `app/` changes
hot-reload; **`lib/` changes (config, resolver, PORO) need a server restart**;
schema changes need `current_scope:install:migrations` + `db:migrate`.

### This session (2026-07-14) — all merged to `main`

Reviewed PR #6 (bots + intent-engineering lenses + a correctness/security/
adversarial cross-model pass), fixed every confirmed finding, then shipped a
run of features and fixes — each its own PR, reviewed, bot-findings addressed,
test-first. Mid-session a **real-app QA gap** surfaced (green unit tests, but the
live UI had a grid-header overlap and a narrow-screen table crush that
`assert_select` can't see); fixed both in a real browser and added a **headless
system-test suite now enforced in CI** so visual/template regressions fail the
build. **Suite now: 243 unit + 19 system green, RuboCop clean.**

- [x] **PR #6** (`65b91c2`) — admin dashboard UI + the review pass: P1 role-save
      privilege-escalation fixed (partial CRUD groups can't silently promote on
      save), bulk subject-class boundary + atomicity + dedup, role-name filter
      correctness, a11y/CSS polish.
- [x] **Members view — PR #7** (`12c11f1`) — each Role lists its org-wide + scoped
      holders with an add-members control (assign from the role side); survives
      stale polymorphic types; org-wide assign returns via `redirect_back_or_to`.
- [x] **v0.2 break-glass — PR #8** (`4d00f69`) — `config.allow_sod_bypass`
      (default off): a privileged, **always-audited** waiver of the SoD veto for
      a flagged record, gated on the initiator holding `bypass_sod`. Resolver
      stays pure (`:sod_bypassed`); Guard records `sod.bypassed` + sets
      `X-Current-Scope-Reason`. Recursion guard (bypass action ∉ `sod_actions`),
      fail-closed hook, no impersonation laundering. README documents it.
- [x] **Resolver memoization — PR #9** (`652710d`) — the org-role lookup is
      memoized on `CurrentScope::Current` (request-scoped), invalidated on any
      `RoleAssignment` write, so a view's N gate checks share one query.
- [x] **Grid header overlap + system tests — PR #10** (`ae90936`) — the sticky
      permission-grid header sat 52px over the first row (a bad PR-#6 offset; its
      sticky container is `.cs-grid-wrap`, so `top` must be 0). Fixed, and added
      the Capybara + cuprite headless system suite + an overlap guard.
- [x] **Subjects table narrow-screen fix — PR #11** (`906d6fe`) — a wide subjects
      table overflowed the page and crushed rows to ~269px on a ~500px window;
      flush-card tables now scroll-x, and below the 820px breakpoint take natural
      width (flat rows). Verified in a real browser both widths.
- [x] **Broadened system coverage + CI — PR #12** (`e0c97dc`) — 17→ system tests
      over the JS/render flows (grid group/partial-guard/row-master, theme toggle
      + persistence, bulk assign, pagination, events ledger, full scoped-picker
      cascade); CI now runs `test:system` in headless Chrome.
- [x] **Deferred P3s + ROADMAP — PR #13** (`0efab4b`) — bulk org-role notice
      counts only actual changes; orphaned assignments removable by id; the
      subjects filter keeps a checked row visible; ROADMAP corrected (audit,
      impersonation, memoization, `scope_for` are shipped).
- [x] **CI action bumps — PR #14** (`fb422fb`) — `actions/checkout`→v7,
      `cache`→v6, `upload-artifact`→v7 (consolidated the three Dependabot majors;
      CI-proven; #1/#2/#4 auto-closed).
- [x] **Subjects server-side search — PR #15** (`e6120e2`) — `?q=` matches every
      subject by identity columns across all pages (was page-scoped client filter
      only). Injection-safe (columns from `column_names`, bound `LIKE` value);
      degrades cleanly when no identity columns exist.

### This session (2026-07-15 → 2026-07-16) — the adoption run

**Lens:** make the engine smooth to adopt for a real existing Rails 8 host that
runs Action Policy today and wants an incremental, reversible retrofit.

**Suite: 422 runs, 1258 assertions, RuboCop omakase clean on `main`** — verified
2026-07-16, green throughout.

#### Merged

- [x] **#37 report-only enforcement — PR #59.** `config.enforcement =
      :enforce | :report`. Report mode downgrades **exactly one** reason
      (`:no_grant`) and lets the request through; every other refusal still 403s,
      matched **positively** so a future reason is a refusal by construction.
      Loud boot warning in production. `rails current_scope:report` reads the
      gaps back out of the ledger.
- [x] **Readiness audit marked complete — PR #60.** It read as a live worklist;
      it is historical (A1–A13, PR #5).
- [x] **#41 dev diagnostics — PR #61.** Three silent failure modes now tell on
      themselves in dev/test: `warn_on_nil_sod_record`,
      `warn_on_inert_scoped_grant`, `warn_on_cross_controller_derivation`.
      Log-only in every environment; **1 flag : 1 nudge**, no bundling.
- [x] **#26 adoption guide — PR #64.** `docs/guides/adopting-in-an-existing-app.md`
      — report mode as the ramp, auth-callback ordering, Devise/engines, the
      `skip_before_action` fail-open, coexisting with Pundit/CanCanCan/Action
      Policy, namespaced grant pairs, a rollout ladder.
      *(Corrected 2026-07-16: this entry originally claimed "the install
      generator points at it and a test asserts the path resolves" — that was
      the discredited `File.exist?` test, and #64's six review fixes — dead-end
      pointer, `NameError` snippet, that test — were committed locally as
      `c01a395` but **never pushed**; the threads were resolved citing a commit
      no ref contained, and the PR merged pre-fix. Found by the audit, rescued
      as **PR #71**.)*
- [x] **Plan 029 (#50) — PR #66.** Thread the collection's model to the resolver
      via `current_scope_model`. Plan only; **#50 is still open, unimplemented.**
- [x] **Learning: a correction is itself a rot event — PR #67.**
- [x] **Refresh of the sketch-learning — PR #68.** Pruned to schema, fixed
      drifted counts, added the sibling seam.

#### Open

- [ ] **PR #69 — plan 030 (#62), awaiting review.** Detect the ungated surface:
      grid honesty + a non-raising tripwire posture + `current_scope:ungated`.
      **Refs #62, does not close it** — the plan is the decision artifact; the
      implementation is a separate PR. Closing on the plan would repeat the exact
      "#37 closes an issue that never did the work" trail #62 was filed about.

#### Filed / amended

- **#62** — the `skip_before_action` fail-open (filed, then amended twice with
  corrections to its own premises).
- **#65** — bounded `full_access`, carrying the refutation that killed plan 029's
  R4 so the next reader does not re-derive it.
- **#50 amended** — two of its "Done when" bullets asked for the withdrawn
  behaviour. *(Corrected 2026-07-16: the amendment had landed only as a
  comment — the body's checklist still demanded the escalation until the audit
  applied it to the body itself, the exact rot mode PR #67 documents.)*

#### What this run actually taught, stated plainly

**Review changed the design on every single PR.** Not the wording — the design.
Treat that as the base rate, not as a run of bad luck.

**Mutation testing caught three things no reviewer did**, including a test that
**could not fail**: `abort` raises `SystemExit`, which is not a `StandardError`,
so it escaped `assert_raises`, killed minitest mid-run, and reported **EXIT 0 on
a truncated suite**. CI would have called that green.

**Two same-day instances of "the correction does not reach the instruction".**
Plan 029's R4 was withdrawn in the reasoning and left standing in the
instructions at **eight** locations; the first corrective pass fixed three and
was reported as fixed. Five reviewers found the rest. That produced PR #67, and
then the same shape recurred while writing plan 030 (caught by the sweep, not by
care). The lesson is mechanical: **after any correction, grep the whole document
for the withdrawn thing BY NAME and classify every hit as refutation-vs-instruction
— first, as the worklist, not last as a formality.**

**"Don't re-derive a condition another component owns"** is the through-line, and
it bit three times: my SoD-blind-spot fix re-enumerated the resolver's record-less
set and missed `String` (`params[:id]`); a ledger-failure hint pattern-matched an
error message instead of asking `Event.missing_events_table?`; and plan 029's
withdrawn R4 re-derived `roles_granting`'s safety condition instead of reading the
one it states. The earlier "prefer a positive closed set" lesson from PR #49 was
**wrong** when reapplied to a predicate gating a *refusal*.

#### The back-and-forth, recorded so it isn't relitigated

- **PR #63 was killed by me** deleting its base branch on merge (GitHub
  auto-closes). Rebuilt as #64. Order is: merge → retarget → *then* delete.
- **A "pass" check does not mean zero findings** — proved repeatedly this run.
  cubic/qodo routinely file P1s on a green PR (cubic filed a conf-9 P1 on #59
  and a conf-10 P0 on #66 seconds after its own check reported success; devin
  filed no P1-severity findings this run — *corrected 2026-07-16*).
- **cubic is one reviewer with three threads, not three reviewers.** A commit
  message this run said "six" and enumerated five.
- **Everything is squash-merged**, so in-branch SHAs die. **Cite PRs, never bare
  SHAs.** The doc that established that rule shipped citing five dead SHAs.
- **A flag is a question, not a failure.** A refresh was queued on my false claim
  that a doc's SHAs were unannotated; they were already annotated as
  historical-by-design. All six flags turned out intentional. I read the flag
  instead of the prose.

### This session (2026-07-16) — intent-engineering audit + remediation (PRs #81, #82, #83, #85)

Scaffolded the project's agent config, ran a five-lens `/ie-audit` over the
full engine, then fixed everything actionable across four PRs — #81, #82,
#83, #85; there is no #84 in this set — all squash-merged in order, review
threads fixed-or-answered first. (The config scaffolding was committed on
`feat/ungated-detection` and reached `main` when that branch merged as #79.)

- [x] **Config scaffolding**: `AGENTS.md` workflow contract (+ thin `CLAUDE.md`
      pointer), `.intense/` (ways-of-working, rails thresholds, pattern
      policy), `.compound-engineering/` example config + gitignore entry.
- [x] **Audit** (5 lenses, all 46 engine source files, run artifacts at
      `wip/intent-engineering/20260716-121400-bc73637d/` — gitignored, report +
      per-lens JSON): posture strong (architecture 8–9, simplicity 8–10,
      dependency restraint 10) with the gaps clustered in experience
      (interaction states 6/10, accessibility 6/10). Kept 2 P1 / 10 P2 / 10 P3.
- [x] **PR #81** — P1s + security-knob P2s: `current_scope_gid_label` rescues
      deleted-record GIDs (events page no longer 500s); picker zero-match
      empty state (keyed off raw search results, not the composite options);
      validating writers for `config.audit` / `config.sod_identity` (a typo
      raises instead of silently weakening; ENV boolean spellings normalized);
      the prod-impersonation env var parses its VALUE — **behavior change:**
      `...=false` no longer enables the opt-in.
- [x] **PR #82** — experience P2s: `role="alert"` on form error banners;
      skip-to-content link (WCAG 2.4.1); confirm on org-role Set (per-row +
      bulk, matching Remove); filter-vs-search hint always renders.
- [x] **PR #83** — predictability P2s: subjects page keys role lookups on
      `polymorphic_name` (STI subjects no longer render "— none —"); `grant!`
      seeds defaults only on the no-role path; `scope_for` doc states the
      row-membership-vs-action-reachability boundary.
- [x] **PR #85** — convention P2 + P3s: resourceful `role_assignments` routes;
      one `Current#impersonating?` (Permissions + MutationGuard delegate); one
      `CurrentScope.label_for` chain — **the ledger now freezes the human
      label** (was "Project #7" in the ledger while the UI said "Apollo");
      no-op nested transactions removed; `PermissionGrid#expand` passes
      unproducible tokens through raw so catalog validation rejects them by
      name (both grid channels share one loud error contract); warn-once
      Hash→`Set`; README documents `Event.record!`'s default-mode no-raise;
      `Current#actor` documents its snapshot round-trip hazard.
- **Deferred with reasons**: finding 16 (eager `GatingReflection` default)
  targets plan-030 code not yet on `main` — apply after it merges; findings
  21/22 (helper/Guard diagnostic-subsystem extractions) carry the audit's own
  tension notes favoring seam-locality — revisit if the files grow.

---

## Verification brief — for a fresh session

> **Audit completed 2026-07-16** (Fable 5, max effort; 8 adversarially-verified
> probes over these targets + 4 question agents). Outcome: **the code held —
> every resolver/report-mode/nudge invariant survived hostile re-derivation and
> is pinned by tests that fail on regression. The paper trail did not.** 60
> brief claims → 34 confirmed, 20 nuanced, 6 refuted; 20 findings survived
> verification. The one P1: **PR #64's review fixes were never pushed** — the
> fix commit (`c01a395`) was dangling-local-only while the review threads were
> resolved citing it; rescued as **PR #71**. Other corrections landed: issue
> #50's body (the Done-when still demanded withdrawn R4 — comment-only
> amendment had never reached it), the stale `roles_granting` safety comment +
> issue #65's citation of it (**PR #72**), and follow-ups filed as **#73**
> (report-mode SoD blind-spot 403 is undiagnosed), **#74**
> (`nudge_on_nil_sod_record` re-derives the resolver's condition and misses the
> String shape — the through-line defect, alive in the diagnostics path),
> **#75** (grid third state for conditional skips), **#76** (skip-gate macro).
> Claims below that the audit falsified are corrected in place and marked
> *(corrected 2026-07-16)*. The guide's #62 mitigation (subclass re-assert) is
> untested on `main`; plan 030's U4 already schedules exactly that test — not
> duplicated.

**Purpose:** a different model, at max effort, independently double-checks this
run. Assume good faith and **verify anyway** — the failure mode throughout was
confident, well-argued, wrong.

### Ground rules

- **The engine is this repo.** The showcase (`../current_scope_showcase`) consumes
  the published gem and was **not touched** this run. Do not audit it for this.
- **Probe, don't trust.** Every claim below was "verified" once already. Two of my
  own pre-flight claims for plan 030 were wrong *after* I said I'd verified them.
- **`main` is green** (422 runs / 1258 assertions). A green suite is **not**
  evidence — see the `SystemExit` test above.
- Cite **PRs and file:line**, never bare SHAs.

### Suggested tooling

- **Context retrieval first** for any "how does X work / where is Y handled"
  question — `mcp__auggie__codebase-retrieval`. Grep only for exhaustive matching.
- **`/ce-review`** over the merged diffs (PRs #59, #61, #64, #66, #67, #68) and
  **`/ie-review`** for the intent lenses (predictability, simplicity, convention).
- **`/ie-validate-plan`** on `docs/plans/2026-07-15-029-*` (on `main`) and on plan 030 —
  `docs/plans/2026-07-16-030-*` lives in **PR #69's branch**
  (`feat/plan-030-ungated-detection`), not on `main` until #69 merges.
- **`/ce-doc-review`** on the two learning docs in `docs/solutions/workflow-issues/`.
- **`mempalace_search`** before assuming anything about prior sessions.
- **cubic MCP** (`mcp__cubic__get_pr_issues`) to re-read what the bots actually
  filed on each PR rather than trusting this file's summary of it.

### Highest-value targets, roughly in order

1. **`lib/current_scope/resolver.rb` decision order and the record-less branch.**
   *(Corrected 2026-07-16.)* Line 49 is the only unbound grant check **that
   decides** — `scoped_grant_exists?` is a second unbound (and
   full_access-inclusive) query, safe solely because it is diagnostics-only and
   its one caller gates a log line. The safety comment the audit found here
   ("BOTH callers bind the grant to a record") was **stale since PR #61 added
   that third caller** — rewritten in PR #72 to name all three shapes; #65's
   quote updated with it. `roles_granting` = full_access ∪ `roles_ticking`;
   `roles_ticking` excludes full_access and exists **solely** because the
   record-less branch binds to nothing.
   **Tripwire for #65** *(corrected — the original here misquoted #65's "a PR
   for this issue" as "any PR ever", and the grep matches two safe queries
   while missing respellings)*: the invariant is that no query that DECIDES may
   match scoped assignments against a full_access-inclusive role set unless it
   binds `resource:` to the exact record or answers in record ids. The durable
   tripwires are the pins `test/collection_scope_gate_test.rb:56-65` and
   `:70-81`.
2. **PR #59's report mode.** The SoD blind spot (a `:no_grant` that means "nobody
   asked the veto", not "the veto passed") was a real, reproduced escalation —
   200 where 403 belonged. Verify `sod_veto_skipped?` is *asked of the resolver*
   and not re-derived, and that `report_only_denial?` still matches positively.
3. **PR #61's `nudge_on_inert_scoped_grant` ordering.** It must run **before** the
   report-mode early return, or it goes silent for exactly the host report mode
   exists for (`guard.rb:117-119`).
4. **PR #69 / plan 030.** Seven reviewers falsified **three of its own claims**
   (KTD-6's "the raise never protected anything"; KTD-8's "the save path never
   learns the mark exists"; KTD-9's "there is no half-marked row"). All three are
   corrected in the plan — **re-probe them rather than trusting the correction.**
   The break-glass one especially: a bare-skipping `ReportsController` yields a
   marked row carrying a **live** `bypass_sod` cell.
5. **Plan 029 / #50.** KTD-3 records a reversal I was refuted on. Verify the
   withdrawal reached the **instructions**, not just the reasoning — that is the
   defect PR #67 documents, and this plan is its specimen.
6. **The dummy app's coverage gaps.** `test/dummy` has **no inherited skip** and
   **no conditional skip** — #62's own defect has no reproduction in this repo.
   `documents` is routed with no controller class; `projects` routes nothing.
   Plan 029's U4 and plan 030's U4 both edit the dummy; check they don't collide.
7. **The two learning docs** in `docs/solutions/workflow-issues/`. Both are about
   this repo's own failures and both have already gone stale once *inside their
   own drafting window*. Re-verify every count and issue-state claim against the
   tracker.

### Questions worth answering independently

- Is **detection-only** (#62) actually the right call, or does the
  `current_scope_skip_gate!` macro dominate? I argued the macro can't stop a host
  writing `skip_before_action` — but that argument partly defeats the grid mark too.
- Is plan 030's **new residual** (a conditional skip stays unmarked, so the grid
  lies "with an air of having checked") acceptable, given `:warn` covers it at
  runtime but only for hosts who included the mixin?
- Does **#43** (stale routes as phantom grid rows) belong inside #62's work rather
  than beside it? Plan 030 builds its detector and declines its badge.
- Is **#45** (migration tooling from Pundit / CanCanCan / **Action Policy**) the
  thing that should actually be next, given the adoption brief names Action Policy
  explicitly? It is parked. Plan 027 is Pundit-first; the brief is not.

---

## Next

1. **PR #69 review → then implement plan 030** as its own PR closing #62.
2. **#45 (parked by the maintainer)** — delivery split already settled: parity
   harness ships in the gem, analyzer ships as a skill. First-PR scope answered
   by the audit (2026-07-16): **Action-Policy-first for the first adapter** —
   Pundit-first has no recorded rationale anywhere, while #45 calls AP the
   "closest cousin", RESEARCH.md modeled the API on it, and the run's lens was
   an AP host. Sequencing: after #50/#65 land as 0.3.0 (migration tooling must
   not certify hosts against semantics about to change). Note: the parking +
   delivery split exist only in this file — record them on issue #45 and amend
   plan 027 (its KTD-1 says skill-only) before the first #45 PR.
3. **#50** — plan 029 is merged and unimplemented. Must release as **0.3.0**, not
   0.2.1: a `~> 0.2.0` pin must not pick up an authorization-semantics change on a
   routine `bundle update`.
4. **#65** — bounded `full_access`. Any fix must narrow to granted record **ids**,
   not a type.
5. Then the docs cluster: **#30, #28, #27, #24** (plan 006 is "relocate and
   complete", not "write").
6. ~~**Publish to RubyGems**~~ — **done.** `v0.2.0` is on RubyGems and the
   showcase consumes it as a normal gem dependency. Releasing now means: bump
   `lib/current_scope/version.rb` + CHANGELOG, tag, `gem push`, then bump the
   showcase's `gem "current_scope"`.
7. **README screenshots** — the UI is clean and verified; capture the dashboard,
   permission grid, subjects, members, events when convenient.
8. Open design questions (DESIGN.md §9): resource hierarchy/cascade,
   multiple org-wide roles, scoped-role capability restriction.

## Still to be done (open design questions — DESIGN.md §9)

- [ ] Resource hierarchy / cascade: should "Editor of Project #7" imply rights
      on the project's reports? (traversal, depth, cycles — not designed)
- [ ] Single vs multiple org-wide roles per subject (currently exactly one, by
      design; union semantics rejected for v0.1)
- [ ] Scoped-role capability restriction (scoped roles currently reuse full
      Role bundles; a restricted per-record capability set is unexplored)
- [x] ~~Host request-spec helper~~ — shipped as `grant_role!` / `grant_scoped_role!` (A3).
- [x] ~~Subjects-page pagination~~ — shipped (A12·1).

## Working notes

- Engine test DB: `RAILS_ENV=test bundle exec rake db:create db:migrate` from
  repo root (engine `bin/rails` lacks db commands).
- Integration-test gotcha: after requesting the mounted engine, the session
  keeps its SCRIPT_NAME — use literal paths (`post "/session"`) for host routes.
- Inside the mounted engine, bare host route helpers resolve against engine
  routes — use `main_app.` (bit us once: `request_authentication`).
- Showcase lives in the sibling repo `current_scope_showcase` and consumes the
  PUBLISHED gem. An engine change reaches it by release + version bump there —
  there is no vendored copy to refresh.
- **Everything is squash-merged.** In-branch SHAs are unreachable from `main` —
  cite **PR numbers** and `file:line`, never bare SHAs.
- **Branch protection on `main`:** lint + test + conversation resolution,
  `strict: true`, 0 approvals. A green check is not zero findings — the review
  bots (cubic and qodo especially; devin files lower-severity) routinely file
  findings on a passing PR. Wait for them — and confirm claimed fixes actually
  reached the remote before resolving threads (see PR #64/#71).
- **Merge order:** merge → retarget dependent branches → *then* delete the base.
  Deleting first auto-closes the stacked PR (it killed PR #63 this run).
- **`wip/` is gitignored.**
- **Mutation-test any security path.** Revert the fix, confirm red. It caught
  three defects no reviewer did on 2026-07-15, including a test that could not
  fail (`abort` raises `SystemExit`, not `StandardError`, so it escaped
  `assert_raises` and reported EXIT 0 on a truncated suite).
