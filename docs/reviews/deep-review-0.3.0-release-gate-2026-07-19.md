# dte-deep-reviewer — 0.3.0 release gate (`102de5d..main`, PRs #88 / #89 / #92)

_2026-07-19 · Tools used: ce-code-review (mode:agent, full roster), ie-review
(mode:agent, 4 lenses; per-lens JSON in `wip/intent-engineering/20260719-113553-cd38d671/`),
majestic `review:rails-code-review` (simplicity, pragmatic, performance, dhh
reviewers), cubic CLI `review --base 102de5d` (clean on the verified real diff)
+ cubic MCP PR scans (#88, #89: 0 open issues) · Tools unavailable: none ·
Front-end lens: skipped — no FE files in the diff (all `lib/`, config
templates, tests)_

## Verdict

**Releasable — no blocker. Health 8.5/10.** All four lenses confirm the
fail-closed core: decision order intact (SoD veto → full_access → org → scoped
→ record-less → deny), the #49/#50 escalations stay closed (read arm derives
from record ids via `scope_for(...).exists?`; non-read arm excludes
full_access), `:model_undeclared` is label-only and cannot flip a deny, and the
new test coverage is strong (94 runs / 251 assertions green re-run by the ce
lens; 78 by majestic). Two 🟠 findings are worth fixing **before the tag** —
both are silent-failure gaps in the new config/diagnostic surface, not
authorization defects — plus one deliberate design pin to consciously
re-affirm.

## Findings

### 🟠 Medium

1. **`collection_read_actions=` silently accepts a Hash or nested array and
   thereby silently un-fixes #65.**
   `lib/current_scope/configuration.rb:182` — `Array({ index: true }).map(&:to_s)`
   → `["[:index, true]"]` (verified in Ruby by the gate, independently of the
   lens): no `#`, so it dodges the keyed-member raise; not a mutating name, so
   it dodges the warning; frozen as a list that can never match, replacing the
   `["index"]` default. Fails **closed** (never widens), but a silently-inert
   security knob is the exact failure the writer's own comment says it exists
   to prevent. **Fix:** raise `ConfigurationError` on any element that is not
   a String/Symbol, mirroring the keyed-member raise. _(majestic; verified by
   gate — confirmed)_

2. **A mis-declared `current_scope_model` fails closed with no diagnostic.**
   `lib/current_scope/resolver.rb:397` (shape guard) + `:427-433` (labeler) —
   a declared type that is a String / abstract class / non-AR PORO is denied
   at the shape guard, but `record_less_denied_for_unknown_type?` requires
   `model.nil?`, so the deny comes back plain `:no_grant` and the
   `warn_on_undeclared_collection_model` nudge never fires. The host declared
   the hook, typo'd the type, and gets a 403 byte-identical to "never
   granted" — the silent-in-the-bad-direction shape the #41 diagnostics exist
   to kill. **Fix:** log-only dev nudge from the shape guard (or broaden the
   label) naming the invalid type; no decision change. _(ie P2; shape traced
   by gate in the diff — confirmed)_

### 🟡 Low

3. **Mutating-action warning covers only `create`/`update`/`destroy`;
   `destroy_all`/`update_all` enter the list unwarned** —
   `lib/current_scope/configuration.rb:202`. The comment at `:154` itself
   cites `destroy_all` as the escalation example, yet the constant doesn't
   catch it. Partial-blocklist-by-design (custom names always evade, the code
   says so), but the two canonical bulk verbs the docs already name are cheap
   to add. Companion test gap: no negative test pins that a non-canonical
   mutating name is accepted without a warning. _(ce + ie — confirmed by both)_
4. **Report mode hard-403s the `:model_undeclared` deny** where the identical
   pre-upgrade request passed as `:no_grant` → `would_deny` row —
   `lib/current_scope/guard.rb:187` + `resolver.rb:67-69`. **Deliberate and
   pinned** (tests + CHANGELOG), but a retrofit host mid-survey is exactly the
   population with `current_scope_record = nil` and no model declared yet.
   Gate decision: re-affirm the pin in the release notes, or add
   `:model_undeclared` to `report_only_denial?`. _(majestic; behavior
   confirmed, problem-status disputed — see below)_
5. **`ambient_collection_model` is public on the `Permissions` mixin** —
   `lib/current_scope/permissions.rb:67`. Internal binding helper that reads
   as host API (and appears in controller `action_methods`). Move under
   `private`. _(majestic — confirmed)_
6. **`skip_before_action :current_scope_check!` actions never stash the
   ambient model**, so a bare `allowed_to?(:index)` in their views fails
   closed where the real GET would allow — the U6 hide-a-link divergence on
   the one unstashed path. Fail-closed, deny-direction only. Document next to
   the skip guidance (class form is the workaround) or stash from a callback
   that survives the skip. _(majestic — suspected)_
7. **Guard comment "the resolver never reads Current itself (PDP purity)" is
   now inaccurate** — `lib/current_scope/guard.rb:137-139`: `Resolver#org_role`
   reads `Current.memoized_org_role` (a lookup cache, not a decision input).
   Reword the load-bearing purity claim. _(ie — confirmed)_
8. **Release-notes items (docs, no code):** (a) confirm CHANGELOG/README state
   the new gate activates only for controllers declaring
   `current_scope_model` (existing hosts stay fail-closed on upgrade); (b) add
   an UPGRADE note that the class form `allowed_to?(:index, Report)` widens on
   upgrade for scoped full_access holders; (c) one line on the trust boundary:
   a wrong `current_scope_model` + scoped full_access grant of that type opens
   the controller's listed reads. _(ce + ie — confirmed)_
9. Minor style, fix when next touched: unused `_record` param on
   `nudge_on_undeclared_collection_model` (`guard.rb:428`, deliberate);
   `MUTATING_ACTION_NAMES` defined mid-class (`configuration.rb:202`); extra
   labeler `exists?` query per record-less deny in prod (`resolver.rb:427` —
   bounded, one per 403, acceptable per its comment trail); resolver matches
   no `.intense/` pattern-catalog entry — classify as `policy_decision_point`
   or list under `allowed`. _(majestic + ie)_

## Confirmed vs disputed

- **Confirmed by ≥2 lenses:** the `destroy_all` warning gap (ce + ie); the
  release-note/upgrade-visibility items (ce + ie); the soundness of the
  two-arm record-less design and the preserved decision order (all four).
- **Single-lens but independently verified by the gate:** finding 1 (Ruby
  one-liner reproduced the coercion) and finding 2 (labeler's `model.nil?`
  precondition read directly in the diff).
- **Disputed:** overall verdict — majestic said NEEDS CHANGES on the strength
  of findings 1 and 4; ce, ie, and cubic said ready/clean. Not averaged: the
  gate's synthesis is "releasable, fix 1–2 first." Finding 4's *existence* is
  agreed; whether it is a defect or a correct pin is a maintainer decision —
  majestic leans "loosen for report-mode hosts," ie's experience-adjacent
  reasoning and the repo's own tests lean "pinned on purpose."
- Cubic found nothing on a range it verifiably processed (log-confirmed real
  36-file diff; its first `origin/102de5d` attempt failed and it recovered).

## What this would replace / overlap

Nothing — this is the release-gate record for 0.3.0. Per-PR gates (ce → ie →
cubic) already ran on #88/#89; this pass adds the cross-lens adversarial check
and the release-scoped items above. Companion gate steps (dte-test-auditor,
/security-review) are recorded separately.
