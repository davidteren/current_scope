---
title: SoD Documentation Gaps — Collection-Action Hole & full_access-Holds-Bypass - Plan
type: docs
date: 2026-07-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
issue: https://github.com/davidteren/current_scope/issues/29
---

# SoD Documentation Gaps — Collection-Action Hole & `full_access`-Holds-Bypass - Plan

## Goal Capsule

- **Objective:** close two documentation gaps in the separation-of-duties (SoD) story that let a reader believe a fraud control holds when it doesn't. **(1)** Listing a *collection* action (e.g. `approve_all`) in `config.sod_actions` is a silent no-op — the veto can never fire on it, so a team that gates `approve` but ships `approve_all` has a bulk self-approval hole. **(2)** With `allow_sod_bypass` on, any `full_access` role *implicitly* holds the bypass permission, so the top-of-README promise that the veto "overrides even full access" quietly stops being true. Both are documented in the SoD / break-glass sections, plus one config doc-comment; **no engine behavior changes.**
- **Authority hierarchy:** this plan → the settled v0.1/v0.2 engine model (`README.md`, `resources/DESIGN.md`, `docs/ROADMAP.md`). The resolver decision order (SoD veto → full_access → org role → scoped role → deny), fail-closed posture, one-org-role-per-subject, resolver **purity** (no writes, no per-decision state, ambient `CurrentAttributes` context), and the deliberate **route-derived catalog** and **opt-in SoD** design are all **immutable**. This is a docs pass: it describes existing behavior accurately, it does not alter a single decision path. Both behaviors the issue names are **correct and intentional** — the gap is that they are underivable from the prose without reading the resolver.
- **Stop conditions:** stop and surface rather than guess if (a) writing the docs reveals the behavior is *not* what the issue's verified evidence says (it is — re-checked against `lib/current_scope/resolver.rb:104-133` and `:139-159` this session), (b) closing gap (2) tempts a code change to exclude `full_access` from the bypass permission — that is a **behavior change for a sibling issue (see Cross-issue coupling), out of scope here**, or (c) the fix would require documenting a mitigation that doesn't actually hold (the advisory `allowed_to?` filter recipe **does** honor the veto even against full_access — verified via decision order; keep it only while that stays true).

---

## Product Contract

> **Product Contract preservation:** documentation issue, no upstream requirements doc (`product_contract_source: ce-plan-bootstrap`). Findings filed and adversarially re-verified against gem source; see the issue body (`04_sod_matrix` scenario, tests 5 and 6d).

### Summary

The engine's SoD veto is deliberately **member-action-only**: `Resolver#sod_decision` returns `:none` for any check whose record isn't a persisted instance (`record.respond_to?(:new_record?)` is false), which is exactly the case for collection actions where `current_scope_record` legitimately returns `nil`. So an action name placed in `sod_actions` only enforces on the *member* route that carries a record; the *collection* route of the same name is unguarded. Separately, break-glass condition 3 ("the initiator holds the bypass permission") is an ordinary `CurrentScope.allowed?` resolve, and `full_access` grants every permission — so once `allow_sod_bypass` is on, every full-access user is bypass-privileged on any record they can flag. Both behaviors are audited and internally consistent; both are missing from the docs where a reader would look. This plan adds a bulk-action warning + the per-record `allowed_to?` filter recipe to the SoD section, a `full_access` caveat to the break-glass section that reconciles the top-of-README claim, and a one-line pointer in the `sod_actions` config comment.

### Problem Frame

Teams adopt SoD precisely for a fraud-control *guarantee*. A guarantee with an undocumented hole is worse than no guarantee, because the team ships believing they're protected. The README today (`README.md:264-272`) frames the nil-record pitfall **only** as a member-action mistake ("if it's a member action, `current_scope_record` must return the record; if it's a collection action, this is expected") — it never says the corollary: **a collection action in `sod_actions` does nothing, and a `approve_all` sibling of a gated `approve` is a bulk self-approval hole.** The mitigation exists and is verified (advisory `allowed_to?(:approve, record)` honors the veto per record, even against full_access, so a bulk action can filter its batch) but is unadvertised. Likewise the break-glass section (`README.md:307-318`) lists the three bypass conditions without noting condition 3 is *trivially* satisfied by full_access — which is exactly the admin population SoD usually targets — leaving the top-of-README line 27 ("overrides even full access. A structural guarantee, not a preference.") silently conditional on `allow_sod_bypass` being off.

### Requirements

- **R1.** The SoD section states plainly that the veto is **member-action-only**: a collection action listed in `sod_actions` can never be veto-enforced (its record is legitimately `nil`), so gating `approve` while shipping an ungated `approve_all` leaves a **bulk self-approval hole**.
- **R2.** The SoD section gives the mitigation recipe: in a bulk/collection action body, filter each record with `allowed_to?(:approve, record)`, which honors the SoD veto **per record, even against a full_access subject** — so the initiator's own records drop out of the batch **while break-glass is off, or for records not flagged for bypass**. The recipe must scope this guarantee: a self-initiated record flagged for bypass (`current_scope_sod_bypassed?` true) whose initiator holds `bypass_sod` is **re-admitted** by `allowed_to?` (it returns `:sod_bypassed`, not a veto), and because advisory checks never write the `sod.bypassed` event, that self-approval is *unaudited* — forward-point to the break-glass caveat (R4/U2).
- **R3.** The bulk-hole warning cross-links to the existing `config.warn_on_nil_sod_record` dev/test tripwire as the way to *detect* an SoD action that was gated with a nil record (already documented for member actions; now explicitly tied to the collection-action case too).
- **R4.** The break-glass section states that condition 3 (initiator holds the bypass permission) is **implicitly satisfied by any `full_access` role**, because full_access grants every permission including `sod_bypass_permission` — so enabling `allow_sod_bypass` makes every full-access user bypass-privileged on any record they can flag.
- **R5.** The top-of-README "overrides even full access" claim (`README.md:27`) is reconciled: the veto is absolute over full_access **while `allow_sod_bypass` is off** (the default); a one-clause caveat or a forward-pointer to the break-glass section removes the contradiction.
- **R6.** The break-glass section recommends granting bypass through a **narrow, explicitly-grantable role**, and being deliberate about who holds full_access, rather than relying on full_access to carry the bypass implicitly.
- **R7.** The `config.sod_actions` doc-comment in `configuration.rb` — the seam where a reader adds `approve_all` — carries a one-line pointer that collection actions can't be SoD-enforced (with a see-README reference), so the caveat is visible at the point of misuse.

---

## Key Technical Decisions

- **KTD-1 — Docs-only; zero behavior change.** Both findings are correct, intentional, audited behavior. The honest fix is to *describe* them, not to "fix" them. The route-derived catalog making collection actions record-less, and full_access granting every key, are load-bearing design choices, not bugs. Changing either (e.g. excluding full_access from the bypass permission, or boot-time-rejecting collection actions in `sod_actions`) is a **behavior change that belongs to a sibling issue**, not this docs pass — see Cross-issue coupling and Open Questions.
- **KTD-2 — Extend the existing README sections, do not add a new guide file.** The gem keeps its entire narrative in `README.md` (there is no `docs/guides/` tree; `docs/` holds plans, roadmap, research, audit). Reuse the two sections a reader already lands on — "Separation of duties (opt-in)" and "Break-glass override" — so the warning sits where the mistake is made. A standalone SoD guide would fragment the one place people read.
- **KTD-3 — The bulk mitigation rests on a verified invariant: advisory `allowed_to?` honors the veto even against full_access.** Because `sod_decision` is **step 1** of `decide` (before the full_access branch at `resolver.rb:42`), `allowed_to?(:approve, record)` for a self-initiated record returns false regardless of the subject's org role — **except when break-glass lifts it**: with `allow_sod_bypass` on and the record flagged (`current_scope_sod_bypassed?` true), `sod_decision` returns `:bypass` and `decide` returns `[true, :sod_bypassed]` (still step 1, ahead of full_access), so a bypass-privileged initiator's own record is *re-admitted* to the batch — and since advisory checks don't audit, unaudited. This is exactly what makes the per-record batch filter a real fix rather than theatre **while break-glass is off or the record isn't flagged**. The recipe must state both the property **and its break-glass caveat** explicitly (it's the non-obvious part), and is only valid while SoD stays ahead of full_access in the decision order (an immutable per Goal Capsule).
- **KTD-4 — Frame gap (2) as an *interaction*, not a *weakness*.** The full_access-holds-bypass behavior is the natural consequence of two documented rules ("full_access grants everything" + "bypass is a grantable permission"). The docs should present it as a composition a reader must account for when deciding who holds full_access — not apologize for it or imply a defect. The actionable takeaway is R6 (grant bypass narrowly; be deliberate about full_access), not "the engine is unsafe."

---

## Implementation Units

### U1. README — collection-action SoD limitation + bulk filter recipe

- **Goal:** make the bulk self-approval hole impossible to miss, and hand the reader the verified mitigation, in the section where they configure SoD.
- **Requirements:** R1, R2, R3.
- **Dependencies:** none.
- **Files:** `README.md` (the "Separation of duties (opt-in)" section, extending the existing nil-record callout at ~264-272).
- **Approach:** after the existing member-action callout, add a short **"Collection actions and bulk endpoints"** note that says directly: the veto is member-action-only; a collection action (e.g. `approve_all`) listed in `sod_actions` is a **silent no-op** because its record is legitimately `nil`, so an initiator can bulk-self-approve through it. Then give the recipe as a small directional snippet — in the collection action body, filter the batch with the advisory API so each record is veto-checked individually:
  ```ruby
  # directional — approve_all: never trust that the batch excludes your own records
  def approve_all
    approvable = Expense.where(id: params[:ids]).select { |e| allowed_to?(:approve, e) }
    # allowed_to? applies the SoD veto per record — the initiator's own drop out
    # (the veto is step 1, ahead of full_access) WHILE break-glass is off, or for
    # records not flagged for bypass. A flagged record whose initiator holds
    # bypass_sod is re-admitted (allowed_to? returns sod_bypassed) and that
    # advisory pass is unaudited — see "Break-glass override".
    approvable.each(&:approve!)
  end
  ```
  Close by cross-linking `config.warn_on_nil_sod_record = true` as the tripwire that logs when an SoD action was allowed with a nil record (i.e. the veto was skipped), noting it now covers the collection case, not just a member action returning nil by mistake.
- **Patterns to follow:** the existing SoD callout's blockquote/warning style (`README.md:264-272`); the "advisory vs gate" distinction already drawn in the break-glass section; keep the honest, plain-language tone of the surrounding prose.
- **Test scenarios:** Test expectation: none — documentation only. The behavior it describes is already covered by `test/integration/sod_matrix_test.rb` (test 5, the passing `approve_all` → 200 that motivates the note) and `guard.rb#nudge_on_nil_sod_record`; no new assertion is added.
- **Verification:** rendered README's SoD section states (a) collection actions in `sod_actions` are unenforced, (b) the `allowed_to?` per-record filter recipe with the "even against full_access" property **and its break-glass caveat** (a flagged, bypass-held self-record is re-admitted and unaudited), and (c) the `warn_on_nil_sod_record` cross-link. A reader gating `approve` can now find, in that section, why `approve_all` isn't protected and what to do.

### U2. README — break-glass `full_access`-holds-bypass caveat + reconcile the "overrides even full access" claim

- **Goal:** state that with break-glass on, full_access implicitly carries the bypass permission, and remove the resulting contradiction with the top-of-README guarantee.
- **Requirements:** R4, R5, R6.
- **Dependencies:** none for build order, but **coupled to U1's content**: the break-glass override documented here is exactly what re-admits a self-initiated, flagged record to U1's bulk filter (`allowed_to?` returns `:sod_bypassed`), so U1's recipe caveat forward-points to this section. Not fully independent — keep the two consistent.
- **Files:** `README.md` (the "Break-glass override (`allow_sod_bypass`)" section at ~307-325, and a one-clause caveat or forward-pointer on the feature-list line at ~27).
- **Approach:** two small edits.
  1. In the break-glass section, right after the three-condition list, add a **caveat** paragraph: condition 3 ("the initiator holds `bypass_sod`") is satisfied by *any grant of that key* — including a `full_access` role, which grants every permission present and future. So turning on `allow_sod_bypass` makes **every full-access user** able to bypass the veto on any record they can flag — precisely the admin population SoD usually targets. This is consistent with "full_access grants everything," but must be a deliberate choice. Recommendation (R6): grant `bypass_sod` through a **narrow, explicitly-scoped role**, and treat *who holds full_access* as part of your break-glass threat model.
  2. On the feature-list line at `README.md:27` ("...overrides even full access. A structural guarantee, not a preference."), add a short caveat/pointer so the claim is scoped to the default: e.g. "— absolute while `allow_sod_bypass` is off (the default); see Break-glass override." Keep it one clause; do not rewrite the bullet.
- **Patterns to follow:** the break-glass section's existing "Be honest about what this is" framing (`README.md:297-300`) — extend that honesty to the full_access interaction; the cross-reference style already used between sections.
- **Test scenarios:** Test expectation: none — documentation only. Behavior is covered by `test/integration/break_glass_test.rb` (test 6d: full_access Owner + flagged record → `sod_bypassed` header) and `guard_sod_bypass_test.rb`.
- **Verification:** the break-glass section states the full_access-holds-bypass interaction and the "grant bypass narrowly" recommendation; the line-27 bullet no longer reads as an unconditional guarantee. A reader enabling `allow_sod_bypass` learns, in that section, that their Owners just became bypass-privileged.

### U3. configuration.rb — `sod_actions` doc-comment pointer

- **Goal:** put the collection-action caveat at the exact line a reader edits to add `approve_all`.
- **Requirements:** R7.
- **Dependencies:** U1 (so the comment can point at the README note U1 adds).
- **Files:** `lib/current_scope/configuration.rb` (the `attr_accessor :sod_actions` doc-comment block, ~lines 11-20).
- **Approach:** append one sentence to the existing comment: the veto only enforces on **member** actions (those carrying a record); a **collection** action listed here is a silent no-op — filter such endpoints per-record with `allowed_to?` instead (see README "Separation of duties"). No code change, comment only.
- **Patterns to follow:** the existing multi-line doc-comment style on the surrounding accessors in `configuration.rb`; keep it to one added sentence, matching the terse house voice.
- **Test scenarios:** Test expectation: none — comment-only change with no runtime surface.
- **Verification:** the `sod_actions` comment mentions the member-vs-collection distinction and points at the README recipe; `bin/rubocop` clean (comment-only, no offenses).

---

## Scope Boundaries

**In scope:** README additions to the SoD and break-glass sections, the line-27 caveat, and a one-sentence `configuration.rb` doc-comment. Documentation of **existing, correct** behavior only.

**Explicit non-goals (preserve deliberate design):**
- Changing the resolver so a collection action in `sod_actions` raises or warns at **boot** — the catalog is route-derived and member/collection status isn't reliably known at config time; the request-time `warn_on_nil_sod_record` tripwire already covers detection. Not this issue.
- Excluding `full_access` from the bypass permission, or making `bypass_sod` non-grantable-via-full_access — a **behavior change** that would contradict "full_access grants everything." Belongs to the sibling issue (Cross-issue coupling), not a docs pass.
- Adding an engine-side per-record filter helper for bulk actions — the advisory `allowed_to?` already is that helper; the recipe uses it. No new API (YAGNI).
- Any new `docs/guides/` file — the README is the gem's single narrative home (KTD-2).

**Deferred to follow-up work:**
- If a maintainer later wants a *report-only / boot-time* signal that a collection action is listed in `sod_actions`, that pairs with the report-only tooling issue (#37) — see Cross-issue coupling — and would be a code change tracked separately.

---

## Open Questions

- **Gap (2) — document only, or also constrain?** This plan documents the full_access-holds-bypass interaction (KTD-1/KTD-4). A maintainer may instead (or additionally) want `bypass_sod` to require an *explicit* grant not satisfied by full_access — but that breaks the "full_access grants everything" invariant and is a design decision for the bypass-grantability sibling issue, not this docs pass. Flagged, not decided here.
- **Line-27 wording:** caveat inline on the bullet, or a bare forward-pointer to the break-glass section? Assumed: a one-clause inline caveat ("absolute while `allow_sod_bypass` is off (the default)") plus the pointer, since the bullet is the first place a reader forms the "overrides full access" belief. Adjust if the maintainer prefers to keep the feature bullet unqualified and rely on the section.

---

## Cross-issue coupling

- **Break-glass feature plan (`docs/plans/2026-07-12-001-feat-sod-bypass-breakglass-plan.md`).** This docs issue is the honest-framing follow-through on that shipped feature: U2 documents a break-glass *interaction* (full_access implicitly holds `bypass_sod`) that the feature plan's R2 ("bypass is a grantable permission") makes true but never spelled out against full_access. The two compose cleanly — U2 extends, does not contradict, that plan's "audited policy override, not SoD" framing.
- **`bypass_sod` grantability sibling (the #20↔#21 permission-keys-drop ↔ bypass-ungrantable cluster).** Gap (2) is *exactly* the surface that cluster would change: if a future issue makes `bypass_sod` require an explicit, full_access-excluded grant, U2's caveat must be revised (the "every full-access user is bypass-privileged" statement would no longer hold). Compose by: land this docs note now describing current behavior; if the grantability change lands later, that plan owns updating U2's paragraph. Name the dependency in that issue so the doc doesn't drift.
- **Report-only / adoption-guide cluster (#37 report-only ↔ #26 adoption guide).** The collection-action detection deferred above (Scope Boundaries) is natural report-only-mode territory: a boot-time or CI advisory that flags collection actions in `sod_actions` would live with #37's tooling, and the adoption guide (#26) is where the bulk-filter recipe from U1 should be cross-referenced so new adopters meet it before shipping an `approve_all`. This plan seeds the recipe in the README; #26 links to it.
