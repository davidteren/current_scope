# CurrentScope — Readiness Audit &amp; Remediation

> Point-in-time audit of the engine (v0.1.0) for real-world adoption, with a concrete
> remediation worklist. **An agent working this doc should address every item, in
> priority order (P0 → P4).** Each item states where it is, why it matters, a fix
> direction, and an acceptance check. Keep the engine suite green + RuboCop omakase
> clean per change, and **add a regression test for every fix** — especially the
> silent-fail-open items (A2/A4/A5/A6). Update STATUS.md as items land.

## Verdict

The gate itself is **trustworthy as designed** — the resolver is fail-closed, SoD truly
overrides `full_access`, the management UI is gated server-side on every action, the
production guardrail fails loud at boot, the ledger is append-only, and there is no
cross-request subject leak or self-escalation path. **No in-gem authorization bypass
was found.** The gaps are three shapes: (1) packaging claims that don't match the code,
(2) security protections that fail **silently** when a host mis-wires them, and (3)
adoption ergonomics. Address them below.

---

## P0 — Fix before real use

### A1 — Gemspec Rails floor is false (Rails-8 API under a `>= 7.1` claim)
- **Where:** `current_scope.gemspec` (`add_dependency "rails", ">= 7.1"`); the management
  UI uses `params.expect` (Rails 8.0+): `app/controllers/current_scope/roles_controller.rb:104`,
  `.../scoped_role_assignments_controller.rb:30-32`, `.../role_assignments_controller.rb:5,32`;
  migrations declare `ActiveRecord::Migration[7.1]`; `README.md:153,283` instruct hosts to
  write `params.expect` too.
- **Why:** on a 7.1/7.2 host every role/grant mutation raises `NoMethodError`, and the
  advertised floor is a lie the README propagates into host controllers.
- **Fix:** set the dependency to `>= 8.0` (+ a sane upper bound) **or** replace every
  `params.expect` with `params.require/permit` and fix the README; align the migration
  version to the real floor.
- **Accept:** gem installs and all mutations work on the *declared* minimum; CI exercises
  that minimum (see A9).

### A2 — Impersonation security goes silently inert when `actor_method` is unset (HIGH)
- **Where:** `lib/current_scope/context.rb:24-25` (`actor` only populated when
  `config.actor_method` is set), `app/models/current_scope/current.rb:19-21` (`actor`
  falls back to `user`), `lib/current_scope/mutation_guard.rb:42-45`,
  `lib/current_scope/resolver.rb:99-105` (SoD `:either`).
- **Why:** the whole act-as security model keys off `actor != user`. A host whose auth
  `current_user` returns the **impersonated** user (the common pattern with impersonation
  libraries) may wire `config.user_method` but forget `config.actor_method`. Then
  `actor == user` **always** → the read-only-while-impersonating `MutationGuard` is dead
  code (an admin can write as the impersonated user), SoD `:either` can never fire, and
  every audit row attributes the action to the impersonated subject — erasing that an
  admin was behind it. It all "works" in manual testing, so the hole is invisible.
- **Fix:** make this fail **loud**, not silent — a boot-time / dev-mode assertion or
  warn-once when an impersonation setup is detectable but `actor_method` is nil; document
  `actor_method` as the security-critical switch (not an optional extra); consider
  requiring it whenever the impersonation mutation gate is engaged. (The gem can't fully
  auto-detect impersonation — the value is loudness + prominent docs.)
- **Accept:** a host that omits `actor_method` in an impersonation setup gets a clear
  signal (per config), never silent inert security; README flags `actor_method` as
  security-critical.

### A3 — No request/system-spec test helper for host apps
- **Where:** `lib/current_scope/test_helpers.rb:20` (`with_current_user` sets
  `Current.user` directly); `lib/current_scope/context.rb:19-25` (`before_action`
  re-resolves and overwrites it on every real request).
- **Why:** `with_current_user` only works for in-process unit/view/component checks. To
  test their own controllers **behind the gate**, a host must sign in through their own
  auth *and* hand-create `Role` + `RoleAssignment` rows. No grant/`sign_in_as_role`
  helper ships.
- **Fix:** ship a request/system-spec helper — e.g. `sign_in_as_role(subject, role:)`
  and a scoped-grant helper — that seeds the role + assignment and survives a real
  request cycle; document it.
- **Accept:** a host request spec can place a subject in a role and assert allow/deny
  through the real gate in a few lines.

---

## P1 — Harden (silent fail-opens on host misconfig)

### A4 — No "was this action gated?" tripwire
- **Where:** `lib/current_scope/guard.rb` (mixin the host must `include`); no auto-include.
- **Why:** any controller not descending from the Guard'd base (an API base controller, an
  engine controller, a hand-rolled `ActionController::Base`) is silently ungated. Contrast
  the routed-but-excluded case, which fails loud (`guard.rb:38-43`).
- **Fix:** an optional `after_action` verify (Pundit `verify_authorized` style) that raises
  if `current_scope_check!` never ran on an action; document base-controller inclusion as
  assumption #1.
- **Accept:** an ungated action is catchable in test/dev.

### A5 — SoD veto silently skipped when `current_scope_record` returns nil
- **Where:** `lib/current_scope/resolver.rb:83` (bails unless the record responds to
  `new_record?`), `guard.rb:45`.
- **Why:** an SoD-gated **member** action whose record hook returns nil lets a subject with
  an org-wide grant through with SoD never applied. Asymmetric: a *present* record with a
  *missing initiator hook* raises loud (`resolver.rb:88-94`), but an *absent* record skips
  silently.
- **Fix:** document that SoD-gated member actions MUST return the record; add a test;
  consider a dev-mode nudge.
- **Accept:** documented + covered by a test.

### A6 — Audit can silently no-op, committing a mutation unaudited
- **Where:** `app/models/current_scope/event.rb:60-70` (rescues `StatementInvalid`,
  warns once, returns nil), `lib/current_scope/configuration.rb:72`.
- **Why:** with `config.audit` on but the `current_scope_events` table missing (partial
  upgrade), the controller transaction commits the mutation with no audit row.
- **Fix:** gate the graceful-degrade behind an explicit "tolerate missing table" flag, or
  require audit-mandatory hosts to verify the migration ran; keep the current default
  documented.
- **Accept:** an audit-mandatory host cannot silently lose events.

---

## P2 — Correctness polish

### A7 — `scope_for` under-lists STI subclasses
- **Where:** `lib/current_scope/resolver.rb:61-65` (filters `resource_type: model.name`)
  vs the gate storing `base_class` (`resolver.rb:113-115`).
- **Why:** `scope_for(SomeSTISubclass)` queries the subclass name and returns nothing,
  while the per-record gate (keyed on `base_class`) would allow those records. Fail-closed
  (hides allowed records) but a correctness bug.
- **Fix:** normalize to `model.base_class.name` in `scope_for`.
- **Accept:** `scope_for(subclass)` returns exactly what the gate allows.

### A8 — View-helper vs gate key can drift under namespaced controllers
- **Where:** `lib/current_scope.rb:96-104` (`permission_key` prefers the route-key form)
  vs `guard.rb:34` (gate always enforces `controller_path#action`).
- **Why:** when a controller's last path segment differs from the record's `route_key`
  (custom-named or namespaced), `allowed_to?`/`scope_for` in a view test a *different*
  permission than the gate enforces → a link shown that 403s, or hidden that would work.
  Not a bypass (the Guard stays authoritative).
- **Fix:** document that helper + gate agree only when controller path == route key; prefer
  full-key `allowed_to?("ctrl#action")` in namespaced views; consider aligning the helper
  default to `controller_path`.
- **Accept:** documented; no silent shown-but-403 in namespaced views.

### A9 — Advertised Ruby/Rails floors are never tested
- **Where:** `.github/workflows/ci.yml` (single Ruby), `Gemfile.lock` (Rails 8.1).
- **Fix:** matrix-test the declared floors (after A1), or set the declared floors to the
  tested reality.
- **Accept:** CI proves the claimed minimums.

---

## P3 — Adoption polish

- **A10 — `config.audit` is undiscoverable.** It's load-bearing (lets a host skip the
  events migration) but absent from the generated initializer
  (`lib/generators/current_scope/install/templates/initializer.rb`) and the README config
  section. Add it to both.
- **A11 — First-Owner bootstrap is console-only.** The management UI requires `full_access`
  to enter, so the first assignment is a manual console step; `lib/tasks/current_scope_tasks.rake`
  is an empty placeholder. Add a `current_scope:grant` rake task + document it.
- **A12 — Pagination / large-table scaling.** Subjects page (`subjects_controller.rb:3`)
  and events index (hard 200 cap, `events_controller.rb:8`) need pagination; the scoped-role
  picker filters labels in Ruby capped at 500 rows (`scoped_role_assignments_controller.rb:8-16`)
  — move to indexed SQL for scale. (`ponytail:`-flagged; fine until tables grow.)

---

## P4 — Publish to RubyGems (vendoring works today → not a *use* blocker)

- **A13 —** Add `CHANGELOG.md`; add gemspec metadata (`changelog_uri`,
  `rubygems_mfa_required`); fix the duplicate homepage/source and open-ended `rails`
  dependency `gem build` warnings; then publish and swap the showcase off its vendored
  path gem for `gem "current_scope"`.

---

## Verified holding — DO NOT regress

These protections were confirmed correct against the source. When touching
impersonation / audit / guard / resolver code, **preserve these invariants and add
regression tests rather than loosening them:**

- Resolver: fixed order, nil subject → deny, SoD evaluated **before** `full_access` (so it
  overrides it), unmatched → deny (`resolver.rb`).
- SoD: `:either` closes the impersonation self-approval path; a missing initiator hook on a
  present record **raises** (fail-loud), never permits.
- Guard: fail-closed on an unknown/excluded permission (raises).
- Management UI: `require_full_access!` with no `only`/`except` on the engine base →
  every action gated server-side; direct hits by a non-admin get 403; no self-escalation
  to a role or `full_access`.
- CSRF inherited (not disabled); all writes via strong params.
- DB + model uniqueness: one org-wide role per subject; scoped-assignment uniqueness.
- Production guardrail: `allow_mutations_while_impersonating = true` in production without
  the env opt-in raises at boot.
- No cross-request subject leak (`CurrentAttributes` resets; test helper snapshots/restores).
- Append-only ledger (`readonly? = persisted?`); a raised audit failure rolls back the
  mutation.
- `scope_for` fail-closed (nil subject → `.none`) and never lists a record the per-record
  gate would deny.

---

## How to work this doc

Address P0 → P4 in order. Each item is small and independently committable. For every fix,
add a regression test — the silent-fail-open items (A2, A4, A5, A6) especially need a test
that fails loudly if the protection is ever removed. Keep the engine suite green and
RuboCop omakase clean on each commit, and tick items off in STATUS.md as they land.
