---
name: current-scope-migrate
description: Assisted migration from Pundit, CanCanCan, or Action Policy to current_scope (issue #45, phases 1–3). Inventories the host app's authorization rules with deterministic AST classifiers, produces a decision report mapping rules onto roles/scoped grants (with the ones only a human can decide), generates a parity harness that diffs old vs new answers over an exemplar matrix (confidence bounded by the manifest) before cutover, generates reviewable role-backfill migrations (enum column or rolify), and applies safe mechanical call-site rewrites behind an explicit --write. Use inside a HOST app that runs Pundit, CanCanCan, or Action Policy and has current_scope installed, when the user asks to "migrate from Pundit/CanCanCan/Action Policy", "adopt current_scope", "backfill roles", "rewrite authorization call sites", or "generate the migration report / parity harness".
---

# current-scope-migrate — Pundit / CanCanCan / Action Policy → current_scope

**Contract (do not exceed it):** by default this skill READS the host app and
WRITES only new files under `docs/current_scope_migration/`,
`config/current_scope_parity.yml`, `lib/tasks/current_scope_migrate.rake`,
and (phase 2) a reviewable migration under `db/migrate/`. It never guesses at
a rule the AST cannot prove. Two writes are **explicit opt-ins, never
defaults**: the `--write` call-site rewriter edits app code only when the
user asks for it (§9), and a generated backfill migration writes to the
database only when the team reviews its decision points and runs it (§10).
All three source systems are supported (#45 phases 1–3).

Run from the HOST app root. `$SKILL_DIR` below is this skill's directory.

## 1. Preflight (stop early, loudly)

- Which system? `bundle show pundit` / `bundle show cancancan` /
  `bundle show action_policy` (or Read `Gemfile.lock`). Pundit and Action
  Policy keep policies in `app/policies/`; CanCanCan keeps
  `app/models/ability.rb`. A host can run more than one — inventory each.
- current_scope installed? Gemfile has it, and `bin/rails runner
  'puts CurrentScope.catalog.keys.size'` prints a nonzero count (routes must
  be loaded for the catalog; a zero catalog means the engine is not mounted /
  gated yet — point at the README install steps and stop).
- Ruby has prism? (bundled ≥ 3.3; on 3.2 the host adds `gem "prism"`).

## 2. Deterministic inventory

```bash
# Pundit and Action Policy (per-model policy classes):
ruby $SKILL_DIR/scripts/policy_inventory.rb app/policies > /tmp/cs_inventory.json
# CanCanCan (the Ability class):
ruby $SKILL_DIR/scripts/ability_inventory.rb app/models/ability.rb > /tmp/cs_ability.json
```

An Ability composed across files (merged abilities, included modules) needs
one run per file — the script takes any path; report the composition in the
decision report so nothing reads as a complete single-file inventory.

`policy_inventory.rb` buckets every policy predicate, Scope#resolve, and
Action Policy `relation_scope` by what the AST
**proves**: `pure_role` / `ownership` / `sod_shape` / `unparseable` (its
`--self-test` documents the exact shapes), and flags Action Policy DSL
(`pre_check`, `alias_rule`, `default_rule`) for human folding.
`ability_inventory.rb` does the same for `can`/`cannot` rules: user-only
guards + no condition = `pure_role` (`can :manage, :all` = the full_access
shape), a record-column-vs-user hash = `ownership`, and everything else —
blocks, `cannot` (subtractive), attribute conditions, non-user guards —
lands in `unparseable` verbatim. When expanding CanCanCan actions to keys,
use its alias chain: `:read` → index/show, `:create` → new/create,
`:update` → edit/update, `:manage` → every routed action of the matching
controllers. A custom `alias_action` appears as its own inventory row —
expand the affected rules' actions through it by hand. Do not re-classify `pure_role`
or `ownership` by reading the code — the script's determinism is the point.
`sod_shape` is different: the AST proves the *shape* (a negated ownership
comparison on an approve-like name), not the *intent* — treat it as a
proposal that always needs human confirmation in the report, and note that
parity typically cannot verify SoD cells (they depend on the
initiator-record pairing), so SoD behavior is verified out-of-band with the
engine's own SoD test recipe.

## 3. Resolve models → controllers (the key-space shift)

Pundit rules are per-model; current_scope permissions are per-controller.
One `PostPolicy` may govern `posts` AND `admin/posts`. Build the mapping from
the same source the engine derives permissions from:

```bash
bin/rails runner 'CurrentScope.catalog.keys.group_by { |k| k.split("#").first }.each { |c, ks| puts "#{c}: #{ks.map { |k| k.split("#").last }.join(" ")}" }'
```

Match each policy's model to controller path(s) by route key (`Post` →
`posts`, `admin/posts`). Where a controller's model is not derivable from its
path (a `DashboardController` rendering Reports), record it — the parity
manifest's `key_models:` needs it.

## 4. Human classification of the residue

For each `unparseable` entry, read the cited `file:line` and propose options
in the report — as judgment, clearly separated from the proved buckets:

- **Attribute/state conditions** (`record.published?`, time windows, quotas):
  current_scope is deliberately not ABAC. Options: keep as a plain guard in
  the controller/model (`head :forbidden unless @post.published?`), or
  restructure the workflow.
- **Delegations** (`edit? = update?`): fold into the target's bucket.
- **Multi-clause conditions** (role check `||` ownership): usually an
  org-wide grant for the role PLUS a scoped role for the owner — propose the
  pair, mark "review required".
- **Metaprogrammed/DSL policies**: report honestly as unparseable, never
  under-count.
- `permitted_attributes`: no current_scope equivalent — flag, out of scope.

## 5. Go/no-go findings (before anyone writes code)

- **One org-wide role per subject** (unique index
  `index_current_scope_one_role_per_subject`). Detect the host's role shape
  (`users.role` column? rolify? habtm roles?) and whether any user holds
  several roles. Multi-role users need a declared precedence or a merged
  role — a **go/no-go finding at the top of the report**, not a footnote.
- **Ownership rules change meaning**: Pundit's `record.author == user` is
  intensional (all my posts, forever); a scoped role is extensional (explicit
  grant rows). Migration needs a backfill (phase 2) plus a grant-on-create
  hook, and grants become revocable data. State this in the report wherever
  bucket `ownership` appears.

## 6. Write the decision report

Create `docs/current_scope_migration/DECISION-REPORT.md`:

1. **Go/no-go** findings (§5).
2. **Proposed roles + grid ticks** — from `pure_role` rows: each distinct
   user-predicate becomes a role; `user.admin?`-true-for-everything becomes
   `full_access: true`; the permission keys come from §3's mapping.
   Note: `Role#permission_keys=` rejects keys not in the routed catalog, so
   seeding must run with routes loaded.
3. **Proposed scoped roles** — from `ownership` rows, each marked
   **review required** with the semantic-shift note.
4. **SoD proposals** — from `sod_shape` rows: propose
   `config.sod_actions = %w[<action>]` + `current_scope_initiator` on the
   model, linking the engine's SoD guide.
5. **Human decisions** — every `unparseable` row: `file:line`, verbatim
   source, proposed options (§4).
6. **Call-site notes** (informational in MVP — no rewrites): `authorize @x` →
   delete (Guard gates it), `policy(@x).update?` / `can?` →
   `allowed_to?(:update, @x)`, `policy_scope(X)` → `scope_for(X)`.
7. **Partial-adoption recipe**: Pundit and current_scope can coexist during
   the migration — controllers not yet migrated add
   `skip_before_action :current_scope_check!` and keep Pundit; migrated
   controllers drop their `authorize` calls. Cut over controller by
   controller; the parity task keeps both honest throughout.

## 7. Generate the parity harness

Copy the three templates (strip the `.tt` suffix). **`cp -n`, never bare
`cp`** — on a re-run, overwriting would wipe the team's filled-in manifest
and the accepted-diffs audit trail; if a target exists, leave it and say so:

```bash
cp -n $SKILL_DIR/templates/current_scope_migrate.rake.tt lib/tasks/current_scope_migrate.rake
cp -n $SKILL_DIR/templates/current_scope_parity.yml.tt   config/current_scope_parity.yml
mkdir -p docs/current_scope_migration
cp -n $SKILL_DIR/templates/accepted_diffs.yml.tt docs/current_scope_migration/accepted_diffs.yml
```

Fill the manifest from what you learned: `old_system:` (pundit | cancancan |
action_policy — parity replays ONE system per run; a host running two
systems runs parity once per system, swapping the knob), one subject
exemplar per proposed
role (§6.2), one record exemplar per model with `ownership` rules,
`scope_models:` = every model whose policy defines `Scope#resolve` (from
§2's inventory — a listed model without an exemplar shows as "scope
UNVERIFIED" instead of silently passing), the `key_models:` overrides from
§3, and `excluded_keys:` for policies that need request context (they
cannot be replayed in-process — say so in the report).

Then run it and attach the first report:

```bash
bin/rails current_scope_migrate:parity || true   # first run WILL diverge — that is the point
```

The task fails CI on any divergence not recorded (with a reason) in
`accepted_diffs.yml`. The team runs it from migration start until cutover.

## 8. Hand off (report stage)

Summarize: counts per bucket, the go/no-go verdict, where the report and
harness live, and the explicit next steps (seed the proposed roles in
report mode, work the human-decision list, keep parity green, then cut
over per the partial-adoption recipe). Offer §9–§10 (rewrites and
backfill) when the team is ready.

## 9. Call-site rewrites (phase 2 — `--write` is the opt-in)

Run report-only FIRST and put the JSON in the decision report:

```bash
ruby $SKILL_DIR/scripts/callsite_rewrite.rb app > /tmp/cs_rewrites.json
```

The rewriter changes only three provable shapes: `authorize @x` deleted
**only** when every proof holds — statement position in a straight-line
def/block body, a side-effect-free argument (bare var/ivar/no-arg call),
alone on its line, not the file of a gate skip, and not a return value
(the last expression of anything except a public controller action);
`policy(@x).update?` → `allowed_to?(:update, @x)`; and
`policy_scope(X)` → `scope_for(X)`. Everything failing any proof —
value-used/conditional/side-effect-arg `authorize`, custom query args,
`permitted_attributes`, every view-template occurrence
(ERB/Haml/Slim/jbuilder) — lands in `reviews` with `file:line` for a
human. Its `--self-test` (run in CI) pins those guarantees.

Only when the user explicitly asks to apply:

```bash
ruby $SKILL_DIR/scripts/callsite_rewrite.rb --write app
```

Then run the host's test suite and the parity task before committing
anything, and walk the `reviews` list by hand. Two caveats to state in the
report: `policy(@x).edit?`/`new?` rewrites keep those action names — the
gate enforces `edit`/`new` as their own keys, unlike Pundit's alias
convention, so check the decision report's key mapping for those; deleting
`authorize` relies on the controller being Guard-gated — confirm with
`bin/rails current_scope:ungated` first.

## 10. Role backfill migration (phase 2 — generated, reviewed, then run)

Detect the host's role shape (Read `db/schema.rb` and the subject model):

- **Enum/string column** (`users.role`) → copy
  `templates/backfill_enum_roles.rb.tt` into
  `db/migrate/<timestamp>_backfill_current_scope_roles_from_enum.rb`.
  One role per user by construction — no precedence needed.
- **rolify** (`rolify` in Gemfile.lock, `roles`/`users_roles` tables) → copy
  `templates/backfill_rolify.rb.tt` similarly. Its two preflights ABORT
  before writing anything: multi-role users unresolved by `PRECEDENCE`
  (the one-org-role-per-subject go/no-go from §5), and rolify
  class-scoped roles (no current_scope equivalent — a human decision).
- Any other shape (habtm role tables, JSON columns): no template — write
  the migration by hand following the enum template's structure, and say
  so in the report.

After copying, replace the template's `ActiveRecord::Migration[8.1]` with
the host's own version tag (match what `bin/rails generate migration` emits
there — e.g. `[8.2]`), and name the copied file with a fresh timestamp.

Fill every DECISION-POINT constant from §6's proposed roles before handing
over. The migrations copy (never move) role data, grant through the
audited `CurrentScope.grant!` path for org-wide roles, and are deliberately
irreversible (the old columns/tables stay intact — rollback is "keep using
the old system"). Grid ticks still come from §6.2 seeding, not from the
backfill. Scoped-grant caveat: direct `ScopedRoleAssignment` writes are not
ledger-recorded (documented engine behavior) — the scoped audit trail
starts at cutover.
