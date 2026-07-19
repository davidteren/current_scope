# /security-review — 0.3.0 release gate (`102de5d..main`, PRs #88/#89/#92)

_2026-07-19 · Files reviewed: 27 (.rb/.erb filter of 36 changed) · Lines
changed: +2121/−129 · Rails 8.1.3 · Tools: Brakeman (standalone via `gem exec`
— not in bundle), bundler-audit, pattern scan, 3 parallel review agents
(injection/XSS, authorization, data-exposure)_

## Verdict

**PASS — no BLOCK items, no WARN items in the release diff.** The
authorization lens — the core one for this engine — traced all six candidate
bypass routes and found none; injection and exposure lenses are clean. One
dependency advisory sits in the engine's own lockfile, outside this diff.

## BLOCK — none

## WARN — none in the diff

- **Dependency advisory (lockfile, predates this diff):**
  `rails-html-sanitizer 1.7.0` — GHSA-cj75-f6xr-r4g7 (XSS, fixed in 1.7.1),
  found by bundler-audit. The lock line did not change in `102de5d..main` and
  the gemspec does not pin it (hosts resolve their own version), so it is
  dev/test-side for the engine — but run `bundle update rails-html-sanitizer`
  before or with the release commit.

## INFO — for awareness

1. **`collection_read_actions` warns only on canonical `create`/`update`/
   `destroy`** (`configuration.rb:202`): a custom mutating name enters the
   list silently — acknowledged in-code as a partial blocklist; escalation
   still requires the action itself to ignore `scope_for`. (Same item as
   deep-review finding 3 / test-audit finding 1.)
2. **`current_scope_model` is a trusted declaration** like
   `current_scope_record`: a wrong type + a scoped full_access grant of that
   type opens the controller's listed reads. Deliberate, documented at every
   seam (README, guard.rb, resolver.rb, #65 KTD-5).
3. **`:model_undeclared` on `X-Current-Scope-Reason`** rides the pre-existing
   every-env denial header; it reveals controller-configuration state, not
   grant structure, and only to a caller already holding a matching grant.

## What the agents verified (traced in code, not asserted)

- **Injection:** both new SQL sites are parameterized hash-form `where`;
  `resource_type: type.base_class.name` is unreachable by non-class values —
  the AR-subclass shape guard rejects strings before `.base_class`; the
  `constantize` in `lib/current_scope.rb:88` predates the diff and is fed only
  by class-definition-time constants; no views changed; no
  eval/send-dynamic/deserialization added.
- **Authorization:** permission keys are always
  `controller_path#action_name`, so `split("#").last` is deterministic for
  namespaced/nested/bare forms — no crafted key confuses
  `collection_read_action?` or `sod_action?`. The advisory path
  (`ambient_collection_model`) is only ever *less* permissive than the gate
  (cross-controller → nil → fail-closed; NO_RECORD stashes nil), and the new
  `CurrentAttributes` are executor-reset per request — no cross-request type
  leak on reused threads. SoD veto precedes every new allow path twice over
  (decide ordering + in-branch refusal). `scope_for`'s permissive `model.all`
  arm is provably unreachable from the record-less gate — org
  full_access/grant short-circuits earlier, so the read arm always answers
  from the id-narrowed subquery. No mass-assignment/CSRF/session surface
  changed. Dummy controllers all gate correctly; no skips added.
- **Exposure:** the two per-request nudges are gated off in production
  (`Rails.env.local?` defaults); the config-time mutating-name warning fires
  every env by design and logs only host-supplied action names; no PII or
  subject identifiers in any new log line; no secrets in the initializer
  template; lockfile delta is only the self-version bump 0.2.0 → 0.3.0;
  schema.rb churn is pure column reordering.

## Automated tool results

- Brakeman (standalone, full engine scan): 1 warning — **verified false
  positive**: `cookies[:current_scope_theme]` in
  `access_denied.html.erb:7` is allowlisted to `%w[light dark]` before the
  `html_safe` interpolation runs; also pre-existing, outside this diff.
- Bundler-audit: 1 advisory (the sanitizer item above).
- Pattern scan (BLOCK+WARN patterns on all changed .rb/.erb): comment-only
  matches plus the pre-existing `constantize` — no hits in new code.
