---
title: UPGRADING 0.4 to 0.5 tells the whole truth - Plan
type: docs
date: 2026-08-24
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/191
---

# UPGRADING 0.4 to 0.5 tells the whole truth - Plan

## Goal Capsule

- **Objective:** the `0.4 → 0.5` section of `UPGRADING.md` names `bin/rails db:test:prepare` in its step list, is findable from the stack trace that sends a host looking for it, and describes the grant-id type change as a silent breakage of named host code shapes rather than a type note. The three places that repeat those upgrade steps (`docs/site/upgrading.md`, the README upgrade callout, and the `CHANGELOG.md` Unreleased entry) stay in sync.
- **Authority hierarchy:** this plan → issue #191 → the verified facts of the #116 real-host bake against `davidteren/miela_app` → the existing voice and structure of `UPGRADING.md`.
- **Execution profile:** documentation only. Four files touched, one new test file plus one test added to an existing test file. No engine code, no new rake task, no doctor command, no migration.
- **Stop conditions:** if the work starts to want a new task, a new config flag, or a code change to make the string-id breakage loud, stop. Issue #191 asks the document to be honest, nothing more. File a separate issue for anything louder. One such issue is already required by this plan: see "Deferred to follow-up work".
- **Tail ownership:** this plan owns the `0.4 → 0.5` text and its three mirrors. It does not own the `#139` `current_scope_parent` section further down the same file, the report-mode guide, the boot-refusal messages in `lib/current_scope/schema_guard.rb`, or the rest of the #116 bake findings (issues filed separately).

---

## Product Contract

> **Product Contract preservation:** no upstream requirements document (`product_contract_source: ce-plan-bootstrap`). Scope comes from issue #191 and from facts verified live during the #116 bake, not inferred.

### Summary

A host that follows `UPGRADING.md` "0.4 → 0.5" exactly ends up one undocumented command away from a 40-line boot failure, and carries two shapes of ordinary application code that the release breaks silently. The document currently states the type change (`grant.subject_id # => "7"`) and moves on. This plan adds the missing command, writes it so the host can find it from the failure text rather than only from the top of the file, and rewrites the string-id subsection so it names the code shapes that break, says plainly that they fail with exit status 0, and clears the query forms that are safe so a reader does not go and rewrite working `where(...)` calls.

### Problem Frame

Two gaps, both hit on the first real upgrade (0.4.0 to 0.5.1 on the `miela_app` host, PostgreSQL, branch `chore/current-scope-bake-116`).

**Gap 1: the test database is left behind.** `UPGRADING.md:103` "What you must do" lists only:

```bash
bin/rails current_scope:install:migrations
bin/rails db:migrate
```

That migrates development. The next `bin/rails test` dies at boot with a 40-line stack trace from the #151 `SchemaGuard`, because the test database still has the integer columns. `bin/rails db:test:prepare` fixes it. The document never names that command anywhere. The guard is behaving correctly. The documented happy path is what is incomplete, and it is incomplete immediately after a security upgrade the same document tells the reader to hurry.

Two facts make this worse than a missing line, and both are verified in this repository:

- Rails normally keeps the test schema current through `ActiveRecord::Migration.maintain_test_schema!`, which `rails/test_help` invokes. That does not save the host here. The engine's guard runs inside `config.after_initialize` (`lib/current_scope/engine.rb:48` to `:54`), which fires while `config/environment` loads. `test/test_helper.rb:9` loads the environment and `test/test_helper.rb:12` requires `rails/test_help` after it, so the guard has already raised before Rails gets the chance to repair the test schema.
- The message the failing host actually reads points at the wrong fix. `lib/current_scope/schema_guard.rb:95` ends with "Run `bin/rails current_scope:install:migrations && bin/rails db:migrate` to widen it", which is exactly the pair the reader has just run. The document has to close that loop, because this plan does not change the message (see "Deferred to follow-up work").

**Gap 2: "grant ids now read back as strings" understates a silent breakage.** `UPGRADING.md:166` states the type change and gives one repair (`compare .to_s on both sides`). On the bake host that change broke two pieces of ordinary application code, neither of which raised:

- A seed that syncs scoped grants compared `[subject_type, subject_id, resource_type, resource_id]` tuples read from grant rows against the same tuples built from live records. Every stored tuple sorted as stale, every wanted tuple as missing, so a re-run **deleted every scoped grant** and created nothing. Exit status 0, no error, no log line.
- An admin page built `assignments.to_h { |a| [a.subject_id, a.role.name] }` and then looked up `hash[user.id]` with an Integer. Every lookup missed and every role rendered blank. Exit status 0.

The document tells a reader that the type changed. It does not tell them which shapes of their own code that breaks, and both failure modes are silent. Separately, a reader who is told only "ids are strings now" tends to over-correct and rewrite working queries, so the document must say which query forms are safe and why.

### Requirements

- R1. The `0.4 → 0.5` step list names `bin/rails db:test:prepare`, with a short rationale that says why Rails does not fix the test database by itself: the engine's guard runs in `config.after_initialize`, which fires while `config/environment` loads, before `rails/test_help` reaches `maintain_test_schema!`.
- R1b. That same step list adds one scoped clause for MySQL hosts on the default `schema_format = :ruby`: `db:test:prepare` loads `schema.rb`, `schema.rb` cannot carry a MySQL collation, so the test columns come out case and accent insensitive and the guard still refuses to boot. Those hosts must also run `RAILS_ENV=test bin/rails current_scope:repair_schema`. The clause names its own exception: a host on `config.active_record.schema_format = :sql` builds the test database from `structure.sql`, which carries the collation, and does not need it. See KTD3 for the evidence.
- R2. That same paragraph is reachable from the failure, not only from the top of the file. It must contain the literal words a host would search for out of the stack trace: `bin/rails test`, `CurrentScope::ConfigurationError`, and `subject_id`. It must also say, in one clause, that the boot message prescribes `install:migrations && db:migrate` and that this pair does not repair the test database.
- R3. The "Every host: grant ids now read back as strings" subsection names the host code shapes that break: tuple or Set comparisons against live ids, hashes keyed by `subject_id` or `resource_id` and then looked up with a model id, and any bare `==` between a stored id and a model id. The existing `grant.subject_id == user.id` example moves into that list rather than being restated beside it.
- R4. That subsection states plainly that all of those shapes fail silently: no exception, exit status 0, and in the seed case, deleted rows.
- R5. That subsection clears the query forms that were actually verified, and bounds the claim to them. `where(subject: user)`, `where(subject_id: user.id)`, and `scope_for` are safe, because Active Record casts the bound value to the column type on the way in. The claim is stated for Active Record hash and record conditions only. A raw SQL fragment (`where("subject_id = ?", user.id)`) or a SQL join that compares the now-varchar column against an integer column bypasses that cast, and the document says to check those by hand rather than claiming a result for them.
- R6. The three documents that repeat the same upgrade steps do not drift: `docs/site/upgrading.md` (published site page for the same section), the README upgrade callout at `README.md:125` to `README.md:135`, and the `CHANGELOG.md` `[Unreleased]` entry.
- R7. The two acceptance criteria are pinned by tests, so a later edit cannot quietly drop them.
- R8. No engine code changes. No new rake task, no doctor command, no config flag.
- R9. The string-id subsection ends with one command the reader can run against their own application to find the shapes. Prose and one shell line, nothing installed.

### Actors

- A1. A host developer upgrading from 0.4 to 0.5 who follows the document literally and then runs the test suite.
- A2. A host developer who never read the document top to bottom, and arrives at it from a `CurrentScope::ConfigurationError` stack trace after `bin/rails test` aborted.
- A3. A host operator whose deploy runs a seed that syncs grants.
- A4. A maintainer editing `UPGRADING.md` later, who must not silently drop the added guidance.

### Key Flows

- F0. Arrive from the failure (the real entry point)
  - **Trigger:** the reader ran the two documented commands, then `bin/rails test`, and got a `CurrentScope::ConfigurationError` naming `current_scope_role_assignments.subject_id`. The message tells them to run the pair they already ran.
  - **Steps:** they search the repository, the docs site, or the page for `CurrentScope::ConfigurationError` or `subject_id`, and land in the new paragraph, which names the test database as the cause and `bin/rails db:test:prepare` as the fix.
  - **Outcome:** the document answers the symptom, not only the plan. Covers R2.
- F1. Upgrade, then test
  - **Trigger:** the reader runs the commands in "What you must do", then `bin/rails test`.
  - **Steps:** with the new step present, the reader has already run `bin/rails db:test:prepare`, so the test database carries the widened columns and the suite boots.
  - **Outcome:** no `SchemaGuard` stack trace. Covers R1.
- F2. Audit your own code for the string-id change
  - **Trigger:** the reader reaches "Every host: grant ids now read back as strings".
  - **Steps:** the subsection lists the three breaking shapes with a one-line example of each, states that they fail silently, clears the verified query forms, and hands over one grep line to run.
  - **Outcome:** the reader searches their app for tuple comparisons and id-keyed hashes, and leaves their `where(...)` calls alone. Covers R3, R4, R5, R9.
- F3. A later maintainer edits the section
  - **Trigger:** someone rewrites the `0.4 → 0.5` section.
  - **Steps:** `test/upgrading_doc_test.rb` fails if `bin/rails db:test:prepare` or the safe-query list disappears from that section.
  - **Outcome:** the regression is caught in CI, not by the next host. Covers R7.

### Acceptance Examples

- AE1. `UPGRADING.md` contains `bin/rails db:test:prepare` inside the `0.4 → 0.5` section (between the `## 0.4 → 0.5: run the migrations` heading at line 91 and the `## 0.4 → 0.5, separately` heading at line 224).
- AE1b. The same block contains `RAILS_ENV=test bin/rails current_scope:repair_schema`, written as a MySQL-only clause, and names the `schema_format = :sql` exception.
- AE2. The "Every host: grant ids now read back as strings" subsection names all three breaking shapes, with the `==` case folded into the list, and says the failures are silent.
- AE3. The same subsection contains the literal string `where(subject_id: user.id)` in its safe-query list, and names the raw SQL and join exception.
- AE4. `docs/site/upgrading.md` names `bin/rails db:test:prepare` in its `0.4 → 0.5` block and says the string-id change breaks host code silently.
- AE5. `bin/rails test test/upgrading_doc_test.rb test/docs_site_test.rb` passes, and turns red if AE1, AE3, or AE4 is reverted.

### Success Criteria

- A reader who follows the document top to bottom does not meet an undocumented failure.
- A reader who arrives from the stack trace finds the fix by searching for words that are in the trace.
- A reader can find their own broken code from the document alone, without a stack trace to point at it (there will not be one).
- No reader is pushed into rewriting a working query, and no reader is told a raw SQL comparison is safe when nobody tested it.

### Scope Boundaries

**In scope**

- The `0.4 → 0.5` section of `UPGRADING.md` (lines 91 to 223), specifically the "What you must do" step list and the "Every host: grant ids now read back as strings" subsection.
- The mirrored `0.4 → 0.5` block in `docs/site/upgrading.md` (lines 56 to 103; the command fence is lines 65 to 68 and the string-id bullet is lines 97 to 99).
- The README upgrade callout at `README.md:125` to `README.md:135`.
- One `[Unreleased]` `### Fixed` entry in `CHANGELOG.md`.
- One new pin test, `test/upgrading_doc_test.rb`, plus one added test in `test/docs_site_test.rb`.

**Out of scope (true non-goals)**

- **The other four documents that carry `install:migrations && db:migrate` are deliberately untouched:** `README.md:150`, `docs/site/quickstart.md:26`, `docs/site/ai-agents.md:24`, and the landing-page quickstart block at `docs/site/index.html:918`. All four are first-install paths, and a first install cannot hit this failure: `lib/current_scope/schema_guard.rb:47` reads `next unless model.table_exists?`, so the guard stays silent while the grant tables do not exist yet. By the time they do exist in the test database, `rails/test_help` has loaded the current `schema.rb`, which already carries the widened columns. The generator's next-steps text (`lib/generators/current_scope/install/install_generator.rb:21`) is the same first-install case. The `AGENTS.md` drift rule makes this enumeration a reviewable claim, so it is written out rather than asserted as a count.
- Any engine code change, new rake task, or doctor command (R8). The #151 `SchemaGuard` is already correct: the bake proved it fires exactly when it should. Making the string-id breakage loud at runtime is not what #191 asks for.
- Rewriting the released `[0.5.0]` and `[0.5.1]` `CHANGELOG.md` entries. Those are the historical record of what shipped. The repo has one precedent for post-tag errata (`CHANGELOG.md:662`) and it is annotated as errata; a documentation gap in `UPGRADING.md` does not meet that bar.
- The `## 0.4 → 0.5, separately: a mis-declared current_scope_parent` section (#139) further down the same file.
- The `docs/guides/` tree. None of those guides restate the 0.4 to 0.5 steps (verified: only `separation-of-duties-and-break-glass.md:63` and `checking-permissions.md:134` link to `UPGRADING.md`, and neither repeats the steps).
- Migrating or repairing anyone's data. "Audit the rows you already have" already covers that and is unchanged.
- Any claim about how MySQL or SQLite compare a varchar column against an integer. The bake host was PostgreSQL, and nothing in this repository tests that comparison, so the document names the risk and stops. This is a narrower exclusion than it looks, and it does not touch the MySQL clause R1b adds: collation is behaviour this repository encodes and tests (`lib/current_scope/schema_guard.rb:144`, the `#151` migration, `lib/tasks/current_scope_tasks.rake:9` to `:12`), while cross-type comparison is not.

**Deferred to follow-up work**

- **No boot-refusal message in `lib/current_scope/schema_guard.rb` says which database failed, so every one of them can send a host to repair the wrong one.** The ticket named one instance; the defect is shared, and all five raise sites belong in the deferral because the single proposed fix (name the failing environment and connection in the message) closes all five in one change (this bullet was validated saying four; see the correction sub-bullet below):
  - `lib/current_scope/schema_guard.rb:91` to `:96` (the column is still integer) ends with "Run `bin/rails current_scope:install:migrations && bin/rails db:migrate` to widen it", which is the pair the failing reader has already run.
  - `lib/current_scope/schema_guard.rb:144` to `:150` (the MySQL collation is case and accent insensitive) says "Run `bin/rails current_scope:repair_schema`" with no `RAILS_ENV=test`. This is the message a MySQL host reads out of a test-environment boot failure, so following it literally repairs development and leaves the host exactly as broken. Same defect as `:95`, same reader, one loop further along.
  - `lib/current_scope/schema_guard.rb:80` to `:84` (the column allows NULL) and `lib/current_scope/schema_guard.rb:110` to `:117` (the collation could not be read) carry the identical bare `bin/rails current_scope:repair_schema` with no environment. They are listed so the enumeration is complete and the follow-up is not filed twice.
  - **Correction made during implementation: there are five boot-refusal messages, not four.** `lib/current_scope/schema_guard.rb:72` to `:78` (the column is a string but too narrow, "holds N characters; CurrentScope needs 64") ends with the same bare `bin/rails current_scope:repair_schema`. Verified by listing every `raise ConfigurationError` in the file and every repair command it names: the boot refusals are at `:73`, `:81`, `:91`, `:113` and `:144`, and the sixth hit, `:133`, is a `Rails.logger.warn` about PAD SPACE rather than a refusal, so it is not in scope. The follow-up issue must cover all five. Everything else in this bullet stands.

  This is the same anti-pattern the repository has already named in its own code: `lib/tasks/current_scope_tasks.rake:14` to `:15` records that the pre-`repair_schema` state left "the boot error prescribing a command that could not possibly fix it". The fix is a message change plus a test, and it is engine code, which R8 excludes.
  **Filed as [#193](https://github.com/davidteren/current_scope/issues/193), "SchemaGuard boot refusals prescribe a repair command but never name which database failed"**, covering all five raise sites. It was opened before this pull request, per the `AGENTS.md` rule that a deferral names its issue rather than saying "later". The `AGENTS.md` deferral rule does not accept "later" on its own. The issue should say: **What** the five `ConfigurationError` messages in `SchemaGuard` name a repair command but never the database that failed. **Why** a host whose test database is the broken one runs the command against development, sees it succeed, and hits the same boot refusal again; the `:91` message additionally names a command pair that cannot repair a schema-loaded database at all. **How** include the environment and the connection's database name in each message, and add a test per raise site pinning that the message names them. Until those messages change, R1b and R2 are what close the loop for the reader, which is why both are requirements here and not niceties.

---

## Planning Contract

### Key Technical Decisions

- **KTD1. `db:test:prepare` joins the step list, it does not get its own subsection.** The reader is already in a numbered-feeling "What you must do" block. A third command with a short rationale keeps the reading order intact. A separate subsection would push it below "If your database was built from `schema.rb`", where a reader who is not on MySQL would skip it.
- **KTD2. The new paragraph is written for search, not only for reading order.** The bake showed the real entry point is a 40-line stack trace, not the top of the file, so the paragraph spells out `bin/rails test`, `CurrentScope::ConfigurationError`, and `subject_id` in full rather than describing them ("the suite fails to boot"). Those are the strings a host pastes into a search box. The cost is three literals in one paragraph; the benefit is that the page answers the symptom.
- **KTD3. MySQL and the test database get one scoped clause, and it names its own exception.** A previous revision of this plan cut this sentence, on the premise that the bake host was PostgreSQL so no evidence supported it, and that the existing "If your database was built from `schema.rb`" subsection already covered it. Both halves of that premise are wrong, and the evidence is in this repository rather than in the bake:
  - `lib/tasks/current_scope_tasks.rake:9` to `:12` names `db:test:prepare` itself as a schema-load path: "A database built by `db:schema:load` / `db:setup` / `db:test:prepare` ... comes out with the right column TYPE and the server's default collation, because schema.rb cannot express a MySQL collation."
  - `lib/current_scope/schema_guard.rb:101` to `:102` says the same in its own comment: "A database built from schema.rb has the right column type and the wrong collation, which is the common case for a new app and for CI."
  - The consequence is mechanical, not speculative. `check_collation!` runs whenever the grant connection is MySQL (`lib/current_scope/schema_guard.rb:87`), and its final branch at `lib/current_scope/schema_guard.rb:144` to `:150` raises `ConfigurationError` for any collation that is not `_bin`. So a MySQL host who runs the plan's three commands still cannot run `bin/rails test`.
  - The existing "If your database was built from `schema.rb`" subsection (`UPGRADING.md:131` to `:144`) does not close this. It never says `RAILS_ENV=test`, and `current_scope:repair_schema` is `task repair_schema: :environment` (`lib/tasks/current_scope_tasks.rake:6`) operating on `CurrentScope::RoleAssignment.connection`, so it repairs the current environment's database only. A reader who follows that subsection repairs development and leaves the test database exactly as broken.

  **Decision:** add two sentences plus one parenthetical to the U1 step list, scoped to the condition rather than stated flatly. On MySQL with the default `schema_format = :ruby`, also run `RAILS_ENV=test bin/rails current_scope:repair_schema`. A host on `config.active_record.schema_format = :sql` builds the test database from `structure.sql`, which carries the collation, and does not need it. Naming the condition answers the earlier `:sql` objection without answering it by silence. This is a statement about collation, which this repository's own code and its `#151` migration encode; it is not a statement about how MySQL compares a varchar column against an integer, which stays out of scope (see Scope Boundaries). Supporting fact for the reader: `current_scope:repair_schema` is in `BOOT_EXEMPT_TASKS` (`lib/current_scope/schema_guard.rb:181` to `:186`), so it runs against a test database the guard otherwise refuses to boot against.
- **KTD4. The string-id subsection gains a short "check your own code for these shapes" list, not a prose expansion.** Three named shapes, one line of example code each, then one line stating the failure is silent. The reader is scanning for their own code, so a list they can pattern-match against beats a paragraph they have to parse. The `grant.subject_id == user.id` example that lines 173 to 178 already carry becomes the third entry in that list, so the point is made once, in one voice.
- **KTD5. The safe-query statement goes last in that subsection, is stated positively, and is bounded.** The subsection currently ends with a half-sentence on the same point ("The engine's own queries are unaffected"), which a reader takes as being about the engine rather than about their code. Restate it as being about the reader's own `where(...)` calls, name the three forms, and give the reason (Active Record casts the bound value to the column type on the way in). Bound it there. The evidence for those three forms is one sweep of one application's Active Record hash and record conditions on PostgreSQL during the #116 bake, so a raw SQL fragment or a join gets named as "check this by hand", with no result claimed for it.
- **KTD6. `docs/site/upgrading.md` stays a summary and gets the minimum.** That page already defers to `UPGRADING.md` for full detail and says so twice. It gets the command in its code block and one clause on the site's existing string-id bullet, not the whole shapes list. The rule the page already follows is: state the fact, link the detail.
- **KTD7. Each document is pinned by the test class that already owns it.** Root `UPGRADING.md` is not a site file, so it gets a new `test/upgrading_doc_test.rb`. `docs/site/upgrading.md` is a site file, so its pin is one new test inside `DocsSiteTest` (`test/docs_site_test.rb`), which is the class that owns published site pages; that class currently reads only `docs/site/index.html` and `docs/site/quickstart.md`, so the change is a new constant, a new test, and one clause in the class comment. This is the decision that settles the earlier draft's contradiction, where the site-page assertion sat in the new non-site class.
- **KTD8. Punctuation stays plain.** Use commas, colons, and parentheses. Do not add em-dashes to the new text even though the surrounding document uses them.

### Assumptions

- The published gem for 0.5.x is not re-released for this change. This is a documentation fix landing on `main`, and the `[Unreleased]` CHANGELOG entry is the correct home, following the precedent of the docs-only entry already at `CHANGELOG.md:122` (the resolver-picture fix).
- Hosts read `UPGRADING.md` from the repository or the docs site. Both are covered by U3.

### Sequencing

U1 and U2 are two edits to the same section of the same file and should land in one pass, in that order (steps first, then the type-change subsection). U3 mirrors them outward. U4 pins them. U4 must come after U1 and U2, because it asserts on the exact strings they introduce.

**Cross-plan collision, expect to rebase `CHANGELOG.md`.** The #190 plan (the report counting denials on deleted records as outstanding for ever) adds a bullet to the same `[Unreleased]` `### Fixed` list that starts at `CHANGELOG.md:73`, and #190 lands first. Whichever branch is second rebases that file. Keep this plan's bullet additive at the end of the list and touch no neighbouring bullet, so the rebase is a one-hunk resolution rather than a merge argument.

---

## Implementation Units

### U1. Name `db:test:prepare` in the 0.4 to 0.5 steps, and make it findable

**Goal:** a reader who follows "What you must do" has a test database that matches, and a reader who is already staring at the stack trace can search their way to the same paragraph.

**Requirements:** R1, R1b, R2. Covers AE1, F0, F1.

**Dependencies:** none.

**Files:**
- `UPGRADING.md` (the "What you must do" block, lines 103 to 112)

**Approach:**

Add the command to the existing fenced block so the three commands read as one sequence:

```bash
bin/rails current_scope:install:migrations
bin/rails db:migrate
bin/rails db:test:prepare
```

Then add a short paragraph directly under the block, before the existing "The columns become `varchar(64)` ..." paragraph. It must carry these five facts and no more:

1. `db:migrate` only migrates development. The test database is a separate database with the same guard on it, so without `bin/rails db:test:prepare` the next `bin/rails test` aborts at boot with `CurrentScope::ConfigurationError` naming `subject_id`. Write those three strings literally: they are what the reader searches for (KTD2).
2. That error message tells you to run `bin/rails current_scope:install:migrations && bin/rails db:migrate`. For the test database that pair is not the fix, because you have already run it. `bin/rails db:test:prepare` is.
3. Rails does not repair this for you, even though it normally maintains the test schema. `maintain_test_schema!` runs from `rails/test_help`, and the engine's check runs earlier, while `config/environment` loads. Say it in one sentence at that level of detail, without naming engine file paths: a reader who knows Rails will otherwise conclude the new step is unnecessary and skip it.
4. Database tasks are exempt from the boot refusal (the document already establishes this lower down), so `db:test:prepare` runs on an unmigrated host.
5. **On MySQL, `db:test:prepare` is not enough on its own.** Write it as two sentences, in this shape: "On MySQL, `db:test:prepare` loads `schema.rb`, which cannot carry a collation, so the test columns come out case and accent insensitive and the engine still refuses to boot. Run `RAILS_ENV=test bin/rails current_scope:repair_schema` as well. (A host on `config.active_record.schema_format = :sql` builds the test database from `structure.sql`, which does carry the collation, and can skip this.)" Keep the `RAILS_ENV=test` prefix visible: it is the whole point, because `current_scope:repair_schema` repairs the current environment's connection only, and the existing "If your database was built from `schema.rb`" subsection lower down never says it. Do not restate the collation escalation story here; that subsection already tells it, and this clause only has to route the MySQL reader to the right database.

Keep it to roughly five or six lines of prose, plus the two MySQL sentences. The section is already long and the reader is mid-upgrade.

**Patterns to follow:** the surrounding paragraphs in this section state the fact, then the consequence, in that order. Match that.

**Test scenarios:** covered by U4 (`names db:test:prepare in the 0.4 to 0.5 section`). No behavioral change in this unit itself.

**Verification:** the `0.4 → 0.5` section contains `bin/rails db:test:prepare`, `bin/rails test`, `CurrentScope::ConfigurationError`, `subject_id`, and `RAILS_ENV=test bin/rails current_scope:repair_schema`. Reading the section top to bottom, the commands are in the order a host would run them, and the MySQL clause reads as conditional rather than as a fourth step for everyone.

---

### U2. Rewrite the string-id subsection as a silent breakage

**Goal:** a reader can find the shapes of their own code that this release breaks, knows nothing will raise, knows which queries to leave alone, and has one command to run.

**Requirements:** R3, R4, R5, R9. Covers AE2, AE3, F2.

**Dependencies:** U1 (same file, same section; land in order).

**Files:**
- `UPGRADING.md` (the "Every host: grant ids now read back as strings" subsection, lines 166 to 187)

**Approach:**

Keep the existing opening (the "affects you even if all your keys are integers" framing and the `grant.subject_id # => "7"` example): it already works. Then, before the existing "A grant is also now refused at write time ..." paragraph, write, in this order:

1. **One sentence that names the danger, first.** Nothing raises. Code that compares a stored id against a model id keeps running and quietly gets the wrong answer.
2. **A "check your own code for these shapes" list** with three entries, each one line of description plus one line of code:
   - Tuple or Set comparisons against live ids. Example shape: comparing `[subject_type, subject_id, resource_type, resource_id]` read from grants against the same tuple built from records. State the consequence explicitly: a sync that computes stale and missing sets sees every stored row as stale and every wanted row as missing, so it can delete every grant and create nothing.
   - A hash keyed by `subject_id` or `resource_id`, then looked up with a model id. Example shape: `assignments.to_h { |a| [a.subject_id, a.role.name] }` followed by `hash[user.id]`. Consequence: every lookup misses and the value renders blank.
   - Any bare `==` between a stored id and a model id: `grant.subject_id == user.id`, which used to be `true`. **This entry replaces the standalone `==` line and the "compare `.to_s` on both sides" sentence that lines 173 to 180 carry today.** Move them into the list. Do not leave the old wording above the list saying the same thing in a different voice; the whole point of the list is that a scanning reader reads it once.
3. **One sentence saying both real cases came from a live upgrade and both exited 0.** Say it plainly. This is the sentence that makes a reader actually go and search their app.
4. **The repair, once, under the list:** compare `.to_s` on both sides. It is the fix for all three shapes.
5. **The safe-query statement, bounded, last.** Name the three verified forms and write the middle one as the literal string `where(subject_id: user.id)`, because U4 pins that string:
   - `where(subject: user)`, `where(subject_id: user.id)`, and `scope_for` are safe. Active Record casts the bound value to the column type on the way in, so a query written against an Integer id still matches. Do not rewrite working queries.
   - Then the boundary, in one sentence: this covers Active Record hash and record conditions. A raw SQL fragment such as `where("subject_id = ?", user.id)`, or a join that compares the column against an integer column, skips that cast, and what happens then depends on your database. Check those by hand. Claim no result for them: the upgrade evidence behind this paragraph is one application's queries on PostgreSQL, and nothing here has been tested on MySQL or SQLite.
   - This replaces the current trailing half-sentence about the engine's own queries.
6. **One runnable line, last of all.** The section's own idiom is to state the risk and then hand over something the reader can run ("Audit the rows you already have" gives a script at lines 189 to 222). Give the cheap version, one line, no new task:

```bash
grep -rn "subject_id\|resource_id" app lib db
```

   With one sentence saying what to look at in the hits: comparisons, hash keys, and tuple or Set members. Not `where(...)` calls.

**Patterns to follow:** the `## 0.1 → 0.2` section is the model for this shape in this document. It leads with the fix, states the silent consequence in bold, then gives a "How to check" list. Mirror that structure at subsection scale.

**Test scenarios:** covered by U4 (`the safe-query list survives`, `the shapes are named`). No behavioral change in this unit itself.

**Verification:** the subsection names all three shapes exactly once each, states the failure is silent, clears the three query forms while naming the raw SQL and join exception, and ends with the grep line. A reader who knows nothing about the gem can act on it.

---

### U3. Keep the three mirrors in sync

**Goal:** the site page, the README callout, and the changelog do not contradict the file they point at.

**Requirements:** R6. Covers AE4.

**Dependencies:** U1, U2 (mirrors follow the source).

**Files:**
- `docs/site/upgrading.md` (the `0.4 → 0.5` block, lines 56 to 103)
- `README.md` (the upgrade callout, lines 125 to 135)
- `CHANGELOG.md` (the `[Unreleased]` `### Fixed` list, which starts at line 73)

**Approach:**

- **`docs/site/upgrading.md`:** add `bin/rails db:test:prepare` to the command block at lines 65 to 68, with one clause after the block noting that the test database is a separate database with the same guard on it, and that the boot error's own suggested command does not repair it. Extend the existing "Grant ids now read back as strings for every host" bullet (lines 97 to 99) with one clause: the change breaks tuple comparisons and id-keyed hashes in host code silently, and `UPGRADING.md` lists the shapes. Do not copy the whole list, and do not restate the safe-query boundary here; the page's established pattern is to state the fact and link the detail, and it already links `UPGRADING.md` twice.
- **`README.md`:** the upgrade callout at line 130 currently says to run `bin/rails current_scope:install:migrations && bin/rails db:migrate`. **Decision: append the third command inline, so the callout reads `bin/rails current_scope:install:migrations && bin/rails db:migrate && bin/rails db:test:prepare`.** The reason is that this callout is a command a reader copies, not a summary they read: a trailing clause naming the command would be read past by exactly the reader the change exists for. Change nothing else in that callout. It already ends with "See UPGRADING.md". Leave the install block at `README.md:150` alone: it is a first-install path (see Scope Boundaries).
- **`CHANGELOG.md`:** add one bullet at the end of the `[Unreleased]` `### Fixed` list, matching the voice of the docs-only entry at `CHANGELOG.md:122` (the six-step resolver picture). Say what was wrong (the 0.4 to 0.5 steps left the test database behind, and the string-id change was documented as a type note rather than a silent breakage) and what it now says. Reference `(#191)`. Touch no neighbouring bullet: #190 edits the same list and lands first, so this file will rebase (see Sequencing).

**Decision on the MySQL clause (R1b): it stays in `UPGRADING.md` only.** Neither mirror repeats it. `docs/site/upgrading.md` follows the state-the-fact-and-link pattern of KTD6 and already links `UPGRADING.md` twice, and the README callout is a copyable command line, not a place for a two-condition caveat. This is a deliberate summary, not drift: the mirrors must not contradict `UPGRADING.md`, and saying less than it does is the pattern both already follow for the whole `schema.rb` and collation story.

**Patterns to follow:** `docs/site/upgrading.md` lines 90 to 102 for the summarize-then-link shape. `CHANGELOG.md` line 122 for a docs-only `Fixed` entry.

**Test scenarios:** covered by U4 (the site page pin in `DocsSiteTest`). The README and CHANGELOG edits are not pinned: a stale README callout is visible on the front page, and pinning a changelog line adds churn without catching a real failure.

**Verification:** the site page, the README callout, and `UPGRADING.md` all name the same three commands. No mirror claims something `UPGRADING.md` does not.

---

### U4. Pin the acceptance criteria in the class that owns each file

**Goal:** a later edit cannot silently drop the command or the safe-query list.

**Requirements:** R7. Covers AE5, F3.

**Dependencies:** U1, U2, U3 (the tests assert on strings those units introduce).

**Files:**
- `test/upgrading_doc_test.rb` (new)
- `test/docs_site_test.rb` (one added constant and one added test)

**Approach:**

**`test/upgrading_doc_test.rb`**, a small `ActiveSupport::TestCase` in the shape of `test/docs_site_test.rb`: resolve the file with `File.expand_path("../UPGRADING.md", __dir__)`, read it once in `setup`, and slice the `0.4 → 0.5` section before asserting, so a match somewhere else in the file (the `#139` section, a future `0.5 → 0.6` section) cannot satisfy the pin. Slice from the `## 0.4 → 0.5: run the migrations` heading to the next line that starts with `## `, which is `## 0.4 → 0.5, separately` at line 224.

Two tests, with the assertion strings fixed here rather than chosen during implementation:

1. `test "the 0.4 to 0.5 section names db:test:prepare"` asserts `assert_includes section, "bin/rails db:test:prepare"`.
2. `test "the string-id subsection still clears the safe query forms"` asserts `assert_includes section, "where(subject_id: user.id)"`.

The MySQL clause from R1b is deliberately not pinned. Adding a third assertion buys little: the clause sits inside the same step block, so any rewrite that drops it almost certainly drops `bin/rails db:test:prepare` too, which the first pin already catches. Those two literals are chosen on purpose. `bin/rails db:test:prepare` is the command itself, so the pin fails exactly when the acceptance criterion is lost. `where(subject_id: user.id)` appears nowhere in `UPGRADING.md` today (verified), so the test is red before U2 and green after, and it is a code form rather than prose, so an ordinary copy edit will not trip it. Do not pin `scope_for`: line 180 already contains it, so that assertion would pass without U2 ever being written.

**`test/docs_site_test.rb`**: add `UPGRADING_PAGE = File.expand_path("../docs/site/upgrading.md", __dir__)` beside the existing `LANDING` and `QUICKSTART` constants, and one test asserting the page contains `bin/rails db:test:prepare`. No section slicing there: the page's only `0.4 → 0.5` command block is the one being edited, and a second one would be the drift this pin is meant to catch anyway. Widen the class comment at lines 3 to 5 by one clause so it says the class covers the published site pages, not only the landing page.

**Patterns to follow:** `test/docs_site_test.rb` (file read in `setup`, `assert_includes` with a message naming what is expected, one behavior per test).

**Test scenarios:**
- Covers AE5. The `0.4 → 0.5` section names `bin/rails db:test:prepare`: passes on the edited file, fails if the command is removed from that section.
- The pin is section-scoped: adding `bin/rails db:test:prepare` to an unrelated section of `UPGRADING.md` does not satisfy the first test. Prove this while writing by temporarily moving the string outside the section.
- The string-id subsection keeps its safe-query list: passes on the edited file, fails if `where(subject_id: user.id)` is removed.
- `docs/site/upgrading.md` names `bin/rails db:test:prepare`: passes on the edited file, fails if the site command block reverts to two commands.

**Verification:** `bin/rails test test/upgrading_doc_test.rb test/docs_site_test.rb` passes. Reverting either U1 or U2 by hand turns it red.

---

## Verification Contract

- `bin/rails test test/upgrading_doc_test.rb test/docs_site_test.rb` passes (note: `rake test` runs nothing and exits 0 in this repository, per `AGENTS.md`).
- `bin/rails test` passes: no other test reads `UPGRADING.md`, so nothing else should move.
- `bin/rubocop` is clean (the new test file and the `DocsSiteTest` addition are the only Ruby touched).
- Manual read-through: open `UPGRADING.md` at the `0.4 → 0.5` heading and read to the `#139` heading. The commands are in runnable order, the string-id subsection names each shape once and clears the query forms with their boundary, and no sentence contradicts another.
- Cross-check: `docs/site/upgrading.md`, the `README.md` upgrade callout, and `UPGRADING.md` name the same three commands.
- Search check for F0: searching the edited section for `CurrentScope::ConfigurationError` and for `subject_id` finds the new paragraph.
- Pre-PR gate per `AGENTS.md`: `/ce-code-review`, `/ie-review`, `/cubic-loop` (local), then local CI green, on the exact commit that becomes the PR head. Docs-only is not a waiver.
- [x] Before the PR is opened: the follow-up issue for the five `SchemaGuard` boot messages that name no database (`lib/current_scope/schema_guard.rb:73`, `:81`, `:91`, `:113`, `:144`) exists as **#193**, and its number is written into the "Deferred to follow-up work" bullet and the PR body.
- Manual MySQL read-back: the new clause is conditional on both the adapter and `schema_format`, and a PostgreSQL or SQLite reader can skip it in one glance without wondering whether it applies to them.

### Definition of Done

- `UPGRADING.md` names `bin/rails db:test:prepare` in the `0.4 → 0.5` steps, says why Rails does not repair the test database itself, and says the boot message's own command does not either (R1, R2).
- The same steps carry the MySQL clause: `RAILS_ENV=test bin/rails current_scope:repair_schema`, scoped to `schema_format = :ruby`, with the `:sql` exception named (R1b).
- The string-id subsection names the three breaking shapes once each, states the failures are silent, clears the three verified query forms with the reason, and names the raw SQL and join exception without claiming a result for it (R3, R4, R5).
- The subsection ends with one grep line the reader can run (R9).
- `docs/site/upgrading.md`, the README callout, and a `CHANGELOG.md` `[Unreleased]` entry agree with it (R6).
- `test/upgrading_doc_test.rb` pins `bin/rails db:test:prepare` and `where(subject_id: user.id)`, section-scoped, and `DocsSiteTest` pins the site page (R7).
- No engine code, no new task, no new flag (R8).
- The deferred `schema_guard.rb` message issue is filed and cited, and it covers all five raise sites, not only `:91`.
- Commit references `(#191)`; PR body opens with plain-language What / Why / How per `AGENTS.md`.

### System-Wide Impact

Documentation only. The GitHub Pages build (`.github/workflows/pages.yml`) publishes `docs/site/`, and its link-rewrite assertions only inspect `docs/SECURITY-CHECKLIST.md`, so the site edit in U3 adds no CI risk as long as no new relative link is introduced there. Add no new relative links in `docs/site/upgrading.md`; use the absolute GitHub URL form the page already uses.

### Risks

- **The section grows long enough that people stop reading it.** It is already the longest section in the file. Mitigation: KTD1 and KTD4 cap the additions at a few lines, the shapes are a scannable list rather than prose, and U2 moves the existing `==` sentence into the list instead of adding beside it, so the subsection gains less than it looks.
- **`CHANGELOG.md` conflicts with the #190 branch.** Both add a bullet to the same `[Unreleased]` `### Fixed` list and #190 lands first. Mitigation: append at the end of the list, touch nothing else in the file, and rebase.
- **Pinning documentation strings can become churn.** Mitigation: U4 pins two code-shaped literals, not sentences, and both are named in this plan rather than chosen while writing.
- **The safe-query paragraph is a claim about someone else's code.** Its evidence is one application's Active Record conditions on PostgreSQL during the #116 bake. Mitigation: R5 and KTD5 bound the claim to Active Record hash and record conditions and send raw SQL and joins to a manual check. If a reviewer wants the adapter behaviour stated, that needs a test in this repository first, which is out of scope here.

### Sources

- Issue #191, `https://github.com/davidteren/current_scope/issues/191` (the What / Why / How and the acceptance criteria this plan implements).
- The #116 real-host bake against `davidteren/miela_app`, branch `chore/current-scope-bake-116`: 0.4.0 to 0.5.1 on PostgreSQL. Source of the two verified silent-failure cases, of the boot stack trace after `db:migrate`, and of the query sweep behind R5.
- `UPGRADING.md` lines 91 to 223 (the section being edited), lines 173 to 180 (the `==` example and the `.to_s` advice that move into the list), lines 189 to 222 (the audit script, the idiom R9 follows).
- `docs/site/upgrading.md` lines 56 to 103 (the mirror), 65 to 68 (the command fence), 97 to 99 (the string-id bullet).
- `README.md` lines 125 to 135 (the upgrade callout) and line 150 (the first-install block that stays untouched).
- `CHANGELOG.md` line 73 onward (the `[Unreleased]` `### Fixed` list) and line 122 (the docs-only entry used as the voice model).
- `lib/current_scope/engine.rb` lines 48 to 54 (`config.after_initialize` calling `SchemaGuard.check!`) and `test/test_helper.rb` lines 9 and 12 (environment loaded before `rails/test_help`): together, why `maintain_test_schema!` cannot save the host.
- `lib/current_scope/schema_guard.rb` line 47 (`next unless model.table_exists?`, why first installs are unaffected), lines 77, 83, 95, 116 and 144 (the repair command in each of the five boot messages that name no database), lines 101 to 102 (schema-loaded databases get the right type and the wrong collation), line 87 (`check_collation!` runs only on MySQL), and lines 181 to 186 (`current_scope:repair_schema` is boot-exempt, so `RAILS_ENV=test` works against a refused database).
- `lib/tasks/current_scope_tasks.rake` line 6 (`task repair_schema: :environment`, why the task repairs one environment only) and lines 7 to 18 (`current_scope:repair_schema`, the comment naming `db:test:prepare` as a schema-load path, and the comment recording the same wrong-prescription failure).
- `UPGRADING.md` lines 131 to 144 (the existing "If your database was built from `schema.rb`" subsection, which never says `RAILS_ENV=test`).
- `test/docs_site_test.rb` (the pin-test pattern, and the class that owns the site-page pin).
- `AGENTS.md` (review gate, testing policy, `rake test` runs nothing, drift rule, deferral names an issue).
