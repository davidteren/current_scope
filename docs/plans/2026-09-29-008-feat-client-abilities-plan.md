---
title: Client Abilities Payload - Plan
type: feat
date: 2026-09-29
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/96
---

# Client Abilities Payload - Plan

Issues #96 and #97 ask for the same advisory snapshot.
#96 is an API client.
#97 is an Inertia shared prop.
This plan adds one Ruby method and two short guide recipes.
It does not add a route, a gem, or a JavaScript package.
Paths below were read on `origin/main` at `a3d4fef`.

## Goal Capsule

- **Objective:** `CurrentScope.abilities_for` returns a versioned snapshot of full access, the org role, that role's permission keys, and bounded scoped id lists taken from `scope_for`.
- **Authority hierarchy:** this plan, then issues #96 and #97, then the denial contract in the existing denial-behavior plan, then `AGENTS.md` (vanilla Rails, fail closed).
- **Execution profile:** One library method, unit tests, and guide text. No mounted endpoint.
- **Stop conditions:** Do not add `inertia_rails`. Do not publish a JavaScript client. Do not weaken the server gate. Do not return an id list that looks complete when it was cut off. Do not scan every model in the host app.
- **Tail ownership:** The scenario apps `07_react_api` and `08_inertia` live in `current_scope_test_scenarios`, not in this repo. Wiring them is a follow-up in that repo.

---

## Product Contract

### Summary

JavaScript and Inertia clients cannot call the resolver.
They need a snapshot so a client can hide a record the snapshot shows is out of reach. The snapshot does not apply the separation-of-duties veto. A listed id can still be refused when the subject started that record.
The snapshot is advisory.
The request gate remains the authority, and a denial still uses the `X-Current-Scope-Reason` header.

### Problem Frame

`scope_for` (`lib/current_scope.rb` line 240 and `lib/current_scope/resolver.rb` line 153) already answers "which ids".
There is no single method that packages that answer for a client.
A helper that returns every id for every model would be a data dump and could disagree with `scope_for` if it used another query.

### Requirements

**Shape**

- R1. `CurrentScope.abilities_for(subject, scopes:, limit:)` returns a Hash with `version`, `full_access`, `org_role`, `permission_keys`, and `scoped`. `scopes` is a list of pairs. Each pair is one model class and one permission string. The method calls `scope_for` once per pair. It does not cross every model with every permission.
- R2. `version` is `CurrentScope::VERSION`. `full_access` is the resolver's boolean. `org_role` is the org role name or `nil`. `permission_keys` is that role's `permission_keys`, or an empty list when there is no org role.
- R3. `permission_keys` is not a substitute for scoped ids. Scoped entries are separate.
- R4. Each scoped entry names the model, the permission, the ids, and `truncated`. Ids come from `scope_for` for that subject, model, and permission.

**Bound**

- R5. `limit` is a required positive integer. `nil`, zero, a negative number, and a string raise `ArgumentError` before any relation is limited. There is no default that returns every id.
- R6. The method fetches at most `limit + 1` ids. It returns at most `limit` ids. `truncated` is true when another id exists. The limited relation is ordered by primary key, so two calls with the same rows return the same cut. Use the ids `scope_for` returns. Do not cast them with `to_i`.
- R7. The ids are an allow list of records the subject may act on, up to the separation-of-duties veto, which this snapshot does not apply. Hide a record only when `truncated` is false and the id is absent. When `truncated` is true, absence is not a denial. `full_access` false plus an empty id list means no access. `full_access` true, or a key in `permission_keys`, can make `scope_for` return every row. A cut entry is then a sample of the table, not a list of exceptions. An empty `permission_keys` list is not full access.

**Authority**

- R8. The method does not change `allow?` or the denial header.
- R9. The guide says the snapshot is stale as soon as a grant changes, and the server is authoritative on the next request. When full access is on, or the key is on the org role, `scope_for` returns every current row, and the snapshot still keeps at most `limit` ids. A complete list goes stale when a row is created or destroyed. A cut list stays a sample. The host builds the snapshot in the same response as the records the client filters.
- R10. No new engine route serves this Hash. The guide shows a one-action host controller for #96 and an Inertia shared-prop recipe for #97 that does not add the `inertia_rails` gem to this engine.

### Acceptance Examples

- AE1. Full-access subject, limit 10, three scoped ids.
  - **Covers:** R1, R2, R6
  - **Given:** the subject has full access and `scope_for` would return three ids.
  - **When:** `abilities_for` is called with limit 10.
  - **Then:** `full_access` is true, `truncated` is false, and the ids are those three.
- AE2. More ids than the limit.
  - **Covers:** R6, R7
  - **Given:** `scope_for` would return more than two ids.
  - **When:** the limit is 2.
  - **Then:** the payload contains two ids and `truncated: true`. Absence of a third id is not a denial.
- AE3. No org role.
  - **Covers:** R2, R3
  - **Given:** the subject has only a scoped grant.
  - **When:** the method runs.
  - **Then:** `org_role` is nil, `permission_keys` is empty, and the scoped entry still lists the granted ids.

### Scope Boundaries

- No authentication. Hosts authenticate before they call the method.
- No Inertia server-side rendering work, no component library, and no Next.js app inside this gem.
- Scenario apps in `current_scope_test_scenarios` are out of this repo's diff.
- The denial-behavior plan `docs/plans/2026-07-15-006-docs-denial-behavior-plan.md` is not rewritten here. The header stays.

### Sources

- `lib/current_scope.rb` `scope_for` at line 240.
- `lib/current_scope/resolver.rb` `scope_for` at line 153.
- `app/models/current_scope/role.rb` `permission_keys` at line 58.
- `lib/current_scope/version.rb` `VERSION`.
- Issues #96 and #97.

---

## Planning Contract

### Key Technical Decisions

- KTD-1. One method, two recipes. #96 and #97 do not get two payload shapes.
- KTD-2. The caller passes `scopes`, a list of pairs. Each pair is one model class and one permission string. The engine does not discover every Active Record model. Discovery would hide cost and would surprise a host that has private tables. The method does not cross every model with every permission.
- KTD-3. Ids are taken by asking `scope_for` and limiting that relation. A second query that re-implements grant matching is forbidden, because the list and the gate would drift.
- KTD-4. The response holds at most `limit` ids. `limit + 1` is how `truncated` is known without a count query. `scope_for` may already pluck every scoped grant id (`resolver.rb` around lines 167 to 173 and 477 to 482). Do not add a second grant query to avoid that pluck.
- KTD-5. Do not mount a controller in the engine. A new URL would be another surface to gate. The host action is documented, not generated.

### High-Level Technical Design

`abilities_for` reads full access and the org role once.
It loops the caller-supplied model and permission pairs.
For each pair it asks `scope_for`, takes `limit + 1` ids, sets `truncated`, and stores `limit` ids.
The guide places that Hash in a host `show` action and, separately, in the host's existing Inertia shared data if the host already uses Inertia.

### Assumptions

- `scope_for` returns a relation that can be limited. If a model returns an array instead, the implementer stops and reports rather than buffering every id.
- `Role#permission_keys` is the list the console already shows. Do not invent a second list.
- Hosts that use Inertia already depend on it in the host app. This gem does not.

### Sequencing

- U1 implements the method and AE1 to AE3.
- U2 writes the two recipes and the staleness and truncation rules.

### Risks

- Returning all ids when `limit` is omitted would ship a data leak as a convenience. R5 makes `limit` required so the call fails closed at the call site.
- Treating `permission_keys` as "allowed ids" would let a client show records the subject cannot open. R3 and the guide forbid that reading. An empty `permission_keys` list is not full access. When `full_access` is true, or the key is in `permission_keys`, a cut entry is a sample of the table.
- Adding `inertia_rails` would break the vanilla-Rails rule in `AGENTS.md`.

---

## Implementation Units

### U1. Add abilities_for

- **Goal:** The method returns the R1 Hash from `scope_for` and the org role, with truncation.
- **Requirements:** R1, R2, R3, R4, R5, R6, R8
- **Dependencies:** none
- **Files:**
  - `lib/current_scope.rb`
  - `test/abilities_for_test.rb` (new)
- **Approach:** Implement `abilities_for` as a class method beside `scope_for`. Raise `ArgumentError` unless `limit` is a positive integer, before any relation is limited. `nil`, zero, a negative number, and a string all raise. Do not call `limit(nil)`. For each pair, call `scope_for` once, order by primary key, take `limit + 1` ids, set `truncated`, and return at most `limit` ids. Store `model` as the class name string, `permission` as the key string, `ids`, and `truncated`. Read `full_access?` and the org role through the existing public API. Do not add a route. Do not add a second grant query.
- **Patterns to follow:** `scope_for` at `lib/current_scope.rb` line 240. Fail closed when the subject is nil: `full_access` false, no org role, empty scoped ids, not an exception that a client could treat as "allow all". Use the ids `scope_for` returns. Do not cast them with `to_i`.
- **Test scenarios:** AE1, AE2, and AE3. A nil subject does not raise and does not list ids. Omitting `limit` raises `ArgumentError`. `nil`, zero, a negative number, and a numeric string raise `ArgumentError` and do not call `scope_for`. Two pairs are not expanded into a cross product. A model is not asked for the other pair's permission. Two calls return the same cut.
- **Verification:** The ids in the payload equal the ids `scope_for` returns for that pair, up to the limit. `allow?` examples elsewhere stay green.

### U2. Document the two transports

- **Goal:** The guide shows the host controller recipe, the Inertia recipe, staleness, and the truncation rule.
- **Requirements:** R7, R9, R10
- **Dependencies:** U1
- **Files:**
  - `docs/guides/checking-permissions.md` or a short new guide linked from it
- **Approach:** Show a host action that renders the Hash as JSON. Show a shared-prop recipe that calls the same method from the host's Inertia setup. State that this gem does not depend on Inertia. State the R7 hide rule in one place: hide a record only when `truncated` is false and the id is absent. When `truncated` is true, absence is not a denial, and the host passes `allowed_to?` for that one record as a page prop. `full_access` false plus an empty id list means no access. `full_access` true, or a key in `permission_keys`, can make a cut entry a sample of the table. An empty `permission_keys` list is not full access. State that the snapshot does not apply the separation-of-duties veto, so a listed id can still be refused when the subject started that record. On a 403 during an Inertia visit, show `X-Current-Scope-Reason` inline. Do not redirect away from that header. Link the existing denial guide. Do not rewrite `docs/plans/2026-07-15-006-docs-denial-behavior-plan.md`. Do not add `inertia_rails`.
- **Patterns to follow:** The existing guide voice. No new gem in the Gemfile.
- **Test scenarios:** No browser product test. If `test/docs_site_test.rb` pins guide links, add the new page to that list only when the suite requires it.
- **Verification:** The guide names both transports, the required limit, the R7 hide rule, the veto limit, the inline 403, and the one-record prop. The engine Gemfile has no Inertia dependency.

---

## Verification Contract

| Check | Command | Proves |
|---|---|---|
| Payload | `bin/rails test test/abilities_for_test.rb` | R1 to R6, the nil subject, and a bad `limit` |
| Gate unchanged | An existing `allow?` example stays green. Do not add a new gate test for this payload. | R8 |
| Guide | The new or updated guide states the R7 hide rule, the veto limit, the inline 403, and the one-record `allowed_to?` prop. | R7, R9, R10 |
| Lint | `bin/rubocop` | Style |
| Dependency | Engine gemspec and Gemfile do not gain `inertia_rails` | R10 |

One test process per checkout.

## Definition of Done

- `abilities_for` matches R1 through R6.
- A truncated payload sets `truncated: true` and returns at most `limit` ids.
- No engine route or Inertia dependency is added.
- The guide covers the host JSON action, the Inertia recipe, staleness, the R7 hide rule, the veto limit, the inline 403, and the one-record prop when the list is cut.
- `allow?` behavior is unchanged.
- Abandoned experiments are not left in the diff.
