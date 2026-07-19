# dte-deep-reviewer — whole codebase on `main` (v0.3.0)

_2026-07-19 · Tools used: Augment codebase-retrieval, authz/security agent,
ie-architecture-reviewer, ie-experience-reviewer, test-suite auditor, cubic
learnings (27), MemPalace prior gate context, same-day docs/reviews/*-0.3.0-release-gate
· Tools unavailable: cubic codebase scan (no data), live shell/suite re-run,
live Brakeman/bundler-audit (relied on same-day security-review)_

## Verdict

**Strong fail-closed engine — health 8.3/10. No confirmed non-admin
authorization bypass.** Residual risk clusters in three places: (1) silent
host-config footguns that disable SoD or un-fix collection-read behavior,
(2) admin self-lockout paths the last-full-access destroy guard does not
cover, (3) management-UI UX/a11y polish. Production adoption still needs the
security checklist (audit `:strict`, actor_method, tripwire, report-mode exit).

This review is **whole-app**, not the release delta. The same-day 0.3.0
release gate remains the authoritative record for the #50/#65 diff alone.

## Findings

### 🔴 High

_None confirmed._ No path traced where a non-`full_access` subject opens the
management UI, smuggles uncataloged permissions, bypasses MutationGuard by
skipping only `current_scope_check!`, or lifts SoD via the UI.

---

### 🟠 Medium

#### 1. `config.sod_actions` Symbol list silently disables SoD
**Where:** `lib/current_scope/configuration.rb:20` (`attr_accessor`);
`lib/current_scope/resolver.rb:464-466` (`include?` string action segment)

**Why:** Matching is string-only. `config.sod_actions = [:approve]` →
`[:approve].include?("approve")` is false → veto never runs → initiator with
an org grant can self-approve. Same class of silence the repo already fixed
for `collection_read_actions=`. Comment at configuration ~164 admits the
footgun is “grandfathered.”

**Fix:** Validating writer: map to strings, freeze, reject non-String/Symbol;
test both `%w[approve]` and `[:approve]`.

**Confirmed by:** security lens + test auditor + source read. **High confidence.**

#### 2. Last full-access protection is destroy-only
**Where:** `app/controllers/current_scope/roles_controller.rb:73-80` (destroy);
`update` at 57-70 has no equivalent. Test covers destroy only:
`test/integration/management_ui_test.rb:148-156`.

**Why:** Unchecking Full access on the sole Owner role and saving locks every
subject out of the console. Same harm class as delete.

**Fix:** On update, if demoting the last full_access role, refuse with the
same alert. Add a mirrored integration test.

**Confirmed by:** security lens + source + test gap. **High confidence.**

#### 3. Clearing the last full-access org-wide holder is unrestricted
**Where:** `role_assignments_controller.rb:76-81` (`clear_org_role`),
`39-51` (`destroy`)

**Why:** Admin can clear their own (or the only) full-access org assignment
and permanently lock the console. Destroy-last-role is guarded; clear-last-
holder is not.

**Fix:** Before clear/destroy of a full_access assignment, require another
full_access org holder (or another full_access role with holders). Integration
test.

**Confirmed by:** security lens + source. **High confidence.**

#### 4. `collection_read_actions=` Hash / nested array silently un-fixes #65
**(open on `main` per release gate; fixed on `chore/0.3.0-pre-tag-fixes`)**

**Where (main gate):** `configuration.rb` writer — `Array({ index: true }).map(&:to_s)`
→ `["[:index, true]"]`, never matches, replaces default `["index"]`.

**Why:** Fails **closed** (never widens) but silently restores pre-#65
semantics — the failure the writer exists to prevent.

**Fix:** Raise on non-String/Symbol elements (already present in pre-tag
worktree at ~190-196).

**Confirmed by:** same-day release gate (Ruby one-liner) + majestic. **High.**

#### 5. Mutating names on `collection_read_actions` — partial blocklist
**Where:** `configuration.rb:216-218` (`create`/`update`/`destroy` only);
docs cite `destroy_all` as escalation example.

**Why:** Putting a non-list action on the list hands scoped full_access
holders that action type-wide via `scope_for(...).exists?`. Custom names
always evade; the two bulk verbs the docs name should at least warn.

**Fix:** Expand `MUTATING_ACTION_NAMES` with `destroy_all`/`update_all`; keep
warn (not raise) for partial-blocklist honesty. Test pins already exist for
`destroy_all` acceptance on pre-tag branch.

**Confirmed by:** security + release gate ce/ie + test audit. **High.**

#### 6. SoD member action with nil record + org grant still skips veto (A5 residual)
**Where:** `resolver.rb:139-141`, `231-232`; pinned
`test/sod_nil_record_test.rb:30-35`

**Why:** Documented fail-open for host misconfig: initiator with org-wide
approve grant and a nil hook self-approves. Scoped record-less SoD is refused;
report mode refuses the blind spot. Org-wide + nil remains.

**Fix:** Product decision — louder prod nudge/raise for SoD actions with nil
record on POST; keep documented residual until then.

**Confirmed by:** all lenses treat as intentional residual. **High.**

#### 7. `actor_method` silent without boundary APIs (A2 residual)
**Where:** `context.rb:22-25`; loud only at `require_actor_method!` on
impersonation boundary APIs

**Why:** Pretender-style hosts where `current_user` is already impersonated
and `actor_method` is never set → MutationGuard + SoD `:either` + audit
attribution all inert.

**Fix:** Docs + optional boot warn; cannot fully auto-detect.

**Confirmed by:** security + READINESS-AUDIT history. **High residual / med exploitability.**

---

### 🟡 Low

#### 8. Default `audit = true` degrades without events table (A6 residual)
**Where:** `event.rb:60-77`. Mutations commit unaudited after warn-once.
**Fix:** Generator/docs default toward `:strict` for production claims.

#### 9. Wrong `current_scope_model` + scoped full_access opens listed reads
**Where:** Trusted declaration (`guard.rb:43-47`, `resolver.rb:354-359`).
**Fix:** No decision change; keep diagnostics; optional pairing macro later.

#### 10. Guard purity comment is stale
**Where:** `guard.rb:137-139` claims resolver never reads Current;
`resolver.rb:82-85` uses `Current.memoized_org_role`.
**Fix:** Reword claim. (Architecture + release-gate ie.)

#### 11. `ambient_collection_model` is public on Permissions mixin
**Where:** `permissions.rb:67-72`. Internal helper in `action_methods`.
**Fix:** `private`.

#### 12. Org-role request memo not busted on Role attribute change
**Where:** Cache bust only on RoleAssignment save/destroy.
**Why:** Same-request demotion of `full_access` can stale-allow until request end.
**Fix:** Bust on Role update, or accept redirect-after-write mitigation.

#### 13. SoD bypass catalog key can drift for non-conventional names
**Where:** `permission_catalog.rb` — fail-closed (ungrantable break-glass), not fail-open.

#### 14. GatingTripwire is opt-in (A4 residual)
Ungated host controllers remain fail-open by omission. Generator should keep recommending it.

#### 15. Report mode allowed in production (boot warn only)
By design for adoption surveys; ops must exit to `:enforce`.

#### 16. UX — role delete confirm understates cascade
**Where:** `roles/index.html.erb:33-35` — “Delete role X?” while destroy
wipes all org + scoped holders (`roles_controller.rb:82-97`).

#### 17. UX — scoped picker labels lack `for=` associations
**Where:** `scoped_role_assignments/new.html.erb` — WCAG 1.3.1 / 3.3.2.

#### 18. UX — subjects per-row Set controls lack subject-scoped aria-labels

#### 19. UX — no empty states on Roles / Events / Subjects tables

#### 20. Test gaps that could miss a fail-open
- Empty-list deny after destroy not driven through real GET (unit only)
- Non-admin mutation POSTs not asserted
- One-org-role-per-subject uniqueness has no regression test
- Symbol `sod_actions` unpinned (ties to finding 1)

#### 21. Release-notes / upgrade visibility (docs)
CHANGELOG is strong on #50/#65; keep UPGRADE notes for class-form widening and
`:model_undeclared` hard-403 in report mode.

---

### ℹ️ Info — verified holding

| Invariant | Status |
|---|---|
| Resolver order + nil subject deny | ✅ |
| SoD before full_access; `:either` closes act-as self-approval | ✅ |
| Missing initiator on present record raises | ✅ |
| Record-less closed set (nil \| Class only) | ✅ |
| Non-read record-less excludes full_access (`roles_ticking`) | ✅ |
| Listed-read arm = `scope_for(...).exists?` | ✅ |
| Unknown/excluded gate key raises | ✅ |
| Management UI `require_full_access!` (no only/except) | ✅ |
| Report mode cannot open console | ✅ |
| MutationGuard separate from permission skip | ✅ |
| Prod impersonation mutations boot-raise | ✅ |
| Subject GID boundary (`is_a?(subject_class)`) | ✅ |
| Resource type from Scopeable registry (no arbitrary constantize of params) | ✅ |
| CSRF inherited; strong params; catalog rejects unknown keys | ✅ |
| Append-only Event (`readonly? = persisted?`) | ✅ |
| No cross-request subject leak (CurrentAttributes) | ✅ |
| Theme `html_safe` allowlisted to light/dark | ✅ |

## Confirmed vs disputed

### Confirmed by ≥2 lenses
- Symbol `sod_actions` silence (security + tests)
- Last full-access destroy-only / clear-holder gap (security + test coverage map)
- `collection_read_actions` mutating partial blocklist (security + gate + tests)
- Dual-hook adoption cost + Guard size (architecture + security trust note)
- Role delete cascade copy + picker labels (experience + controller cascade read)
- Empty-list deny integration gap (test auditor + prior gate)
- Stale purity comment (architecture + prior gate ie)
- Core fail-closed order and #49/#50/#65 soundness (all lenses)

### Single-lens, source-verified
- Org-role memo not busted on Role update (security)
- Admin search LIKE wildcards (security — admin only)
- Page titles / empty states / aria on subjects (experience)
- System tests text coupling vs AGENTS stable-id policy (tests)

### Disputed / product decisions
| Topic | Positions |
|---|---|
| Is A5 (nil SoD + org grant) a defect? | Security: residual hole. Product/tests: intentional documented pin. **Keep as residual + loud docs.** |
| Report mode hard-403 on `:model_undeclared` | Gate majestic: consider loosening. Tests/CHANGELOG: deliberate pin. **Keep pin.** |
| Should last-full-access update guard block 0.3.0 tag? | Security: yes if easy. Architecture: operator safety, not PDP. **Recommend fix before tag; not a non-admin bypass.** |
| Guard extraction | Architecture: optional when next nudge lands. Ponytail: do not extract for cleanliness alone. **Defer.** |

### Overlap with same-day 0.3.0 release gate
| Gate finding | This whole-app review |
|---|---|
| Hash `collection_read_actions` silence | #4 — open on main; fixed on pre-tag branch |
| Mis-declared model no diagnostic | Partially superseded — worktree has `:model_invalid` labeling |
| destroy_all warning gap | #5 |
| Report mode × model_undeclared | Disputed — keep pin |
| ambient_collection_model public | #11 |
| Purity comment | #10 |

## What this would replace / overlap

- Complements (does not replace) `docs/reviews/*-0.3.0-release-gate-2026-07-19.md`
- Complements historical `docs/READINESS-AUDIT.md` (A1–A13 done; residuals A2/A4/A5/A6 restated with current file:lines)
- Does not replace production security checklist docs already in `docs/plans/` / README

## Health score rationale

| Dimension | Score |
|---|---|
| Fail-closed PDP correctness | 9.5 |
| Host misconfig loudness | 7.5 |
| Admin operator safety | 7.0 |
| Architecture clarity | 8.5 |
| UI / a11y | 7.5 |
| Test trust | 8.5 |
| **Overall** | **8.3** |
