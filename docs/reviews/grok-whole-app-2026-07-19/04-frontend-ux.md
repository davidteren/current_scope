# Frontend / experience lens — management UI

_2026-07-19 · ie-experience-reviewer_

## Verdict

**UX health: 7.5 / 10.** Intentionally designed admin console (tokenized
light/dark, skip link, dual confirms, progressive enhancement) — not AI-slop
chrome. List empty states, cascade-delete copy, and a few AT associations still
leave operators guessing.

## Strengths

- Design tokens + theme toggle; `prefers-reduced-motion`; `:focus-visible`
- Skip-to-content → `#cs-main-content`
- Destructive actions dual-guarded (`data-cs-confirm` + `data-turbo-confirm`) with JS that works without Turbo
- Permission grid: sticky headers, partial/ungated states with text (not color-only), stable `perm_*` / `cs_ungated_*` ids
- Scoped picker: GET cascade vs POST grant (CSRF-safe); empty states for no types / no records / no matches
- Theme cookie `html_safe` allowlisted; event ledger text escaped by default

## Findings

### 🟠 Role delete confirm understates cascade wipe
**Where:** `app/views/current_scope/roles/index.html.erb:33-35`  
**Why:** Confirm is only `Delete role #{name}?` while destroy cascade-removes all org + scoped holders (`roles_controller.rb:82-97`).  
**Fix:** Include holder counts; use `cs-btn-danger` (token exists, unused).

### 🟠 Scoped-picker labels not associated with controls
**Where:** `scoped_role_assignments/new.html.erb`  
**Why:** Bare `<label>` without `for=` — fails WCAG 1.3.1 / 3.3.2. Role edit forms do this correctly.  
**Fix:** `label_tag` matching each `select_tag` id.

### 🟠 Per-row org-role controls lack subject context for AT
**Where:** `subjects/index.html.erb` row select / “Set”  
**Why:** Identical “none / Set” on every row; bulk select already has `aria-label`.  
**Fix:** Per-subject `aria-label` on select and submit.

### 🟡 Empty states missing on Roles / Events / Subjects
Members + picker have empty copy; primary tables do not.

### 🟡 Document title never changes
Layout hardcodes `<title>CurrentScope</title>` — use `content_for :title`.

### 🟡 Access-denied page is a dead end
Correctly layout-less; add one return link to host root or configurable path.

### 🟡 Cascade autosubmit has no busy state
`application.js` `requestSubmit` with no `aria-busy`.

### 🟡 Stable DOM ids incomplete vs AGENTS.md
Grid complies; many other interactive controls rely on text / `data-cs-*` only.

### 🟡 Client filter empty not live-announced
Add `role="status"` / `aria-live="polite"`.

### 🟡/P3 Grant button vanishes until ready
Prefer disabled primary with helper text.

### 🟡/P3 Delete uses neutral button; danger style unused

## CSRF / XSS / Turbo

| Check | Result |
|---|---|
| CSRF | `csrf_meta_tags`; mutating forms POST; cascade GET avoids tokens in URLs |
| XSS | Theme allowlist; no bare `raw` of user content |
| Turbo confirm | Subjects + role delete dual-path; members Remove is cs-confirm-only (JS covers) |
| Keyboard | Native controls; focus-visible; skip link |

## Dimensional scores

| Dimension | Score |
|---|---|
| Information architecture | 8 |
| Interaction-state coverage | 6 |
| User-flow completeness | 7 |
| Accessibility | 7 |
| Look-and-feel consistency | 9 |
