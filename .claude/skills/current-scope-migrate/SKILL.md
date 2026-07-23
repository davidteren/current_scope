---
name: current-scope-migrate
description: Assisted migration from Pundit to current_scope (issue #45, MVP — report-only). Inventories the host app's Pundit policies with a deterministic AST classifier, produces a decision report mapping rules onto roles/scoped grants (with the ones only a human can decide), and generates a parity harness that proves old and new systems agree before cutover. Use inside a HOST app that runs Pundit and has current_scope installed, when the user asks to "migrate from Pundit", "adopt current_scope in a Pundit app", or "generate the migration report / parity harness".
---

# current-scope-migrate — Pundit → current_scope (MVP: report-only)

**Contract (do not exceed it):** this skill READS the host app and WRITES only
new files under `docs/current_scope_migration/`, `config/current_scope_parity.yml`,
and `lib/tasks/current_scope_parity.rake`. It never edits existing app code,
never writes to the database, and never guesses at a rule the AST cannot prove.
Phases 2–3 of #45 (backfill generator, `--write` rewrites, CanCanCan / Action
Policy) are not this skill — say so if asked.

Run from the HOST app root. `$SKILL_DIR` below is this skill's directory.

## 1. Preflight (stop early, loudly)

- Pundit present? `grep -q pundit Gemfile.lock` and `app/policies/` exists.
- current_scope installed? Gemfile has it, and `bin/rails runner
  'puts CurrentScope.catalog.keys.size'` prints a nonzero count (routes must
  be loaded for the catalog; a zero catalog means the engine is not mounted /
  gated yet — point at the README install steps and stop).
- Ruby has prism? (bundled ≥ 3.3; on 3.2 the host adds `gem "prism"`).

## 2. Deterministic inventory

```bash
ruby $SKILL_DIR/scripts/policy_inventory.rb app/policies > /tmp/cs_inventory.json
```

The script buckets every policy predicate and Scope#resolve by what the AST
**proves**: `pure_role` / `ownership` / `sod_shape` / `unparseable` (its
`--self-test` documents the exact shapes). Do not re-classify the first three
buckets by reading the code — the script's determinism is the point.

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

Copy the three templates (strip the `.tt` suffix):

```bash
cp $SKILL_DIR/templates/current_scope_parity.rake.tt lib/tasks/current_scope_parity.rake
cp $SKILL_DIR/templates/current_scope_parity.yml.tt  config/current_scope_parity.yml
mkdir -p docs/current_scope_migration
cp $SKILL_DIR/templates/accepted_diffs.yml.tt docs/current_scope_migration/accepted_diffs.yml
```

Fill the manifest from what you learned: one subject exemplar per proposed
role (§6.2), one record exemplar per model with `ownership` rules, the
`key_models:` overrides from §3, and `excluded_keys:` for policies that need
request context (they cannot be replayed in-process — say so in the report).

Then run it and attach the first report:

```bash
bin/rails current_scope_migrate:parity || true   # first run WILL diverge — that is the point
```

The task fails CI on any divergence not recorded (with a reason) in
`accepted_diffs.yml`. The team runs it from migration start until cutover.

## 8. Hand off

Summarize: counts per bucket, the go/no-go verdict, where the report and
harness live, and the explicit next steps (seed the proposed roles in
report mode, work the human-decision list, keep parity green, then cut
over per the partial-adoption recipe). Remind that phases 2–3 of #45
(backfill, rewrites, CanCanCan/Action Policy) are tracked on the issue.
