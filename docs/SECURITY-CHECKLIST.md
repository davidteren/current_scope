# Security & going to production

> One findable checklist for the places CurrentScope's fail-closed promise can
> quietly become fail-open or leak information. Read this before shipping.
> Issue [#32](https://github.com/davidteren/current_scope/issues/32).

Related: [README](../README.md) · [Adoption guide](guides/adopting-in-an-existing-app.md) ·
solid-solution worklist (S13).

---

## 1. Excluded + skipped = unprotected

**After `skip_before_action :current_scope_check!` on an excluded controller,
CurrentScope enforces nothing on that controller.** The host must supply its
own authorization (`require_admin!`, Devise `authenticate_admin!`, etc.).

### How people get there

1. `config.excluded_controllers += [/\Aadmin\//]`
2. Gate a route under that path → loud `ConfigurationError` (good)
3. Follow the error's advice: `skip_before_action :current_scope_check!`
4. A signed-in user with **zero** CurrentScope grants still reaches the action

### Safe shapes

| Shape | OK? |
|---|---|
| Don't exclude — leave it in the grid and grant carefully | Yes |
| Exclude + skip **and** host auth on the same base controller | Yes |
| Exclude + skip only | **No** — BYO auth or you are open |

The inverse mistake (a controller that never included `Guard`) is what
`CurrentScope::GatingTripwire` and `bin/rails current_scope:ungated` catch.

---

## 2. 403 vs 404 leaks which records exist

The gate loads `current_scope_record` **before** deciding. That is deliberate —
scoped roles and SoD need the record. Side effect:

| Request | Unauthorized / no-grant caller sees |
|---|---|
| Member action, id exists | **403** (`no_grant`) — hook loaded the row, gate denied |
| Member action, id missing | **404** — `RecordNotFound` inside the hook, before decide |

An unauthorized caller can probe which ids exist. Anonymous requests also
trigger real DB loads for those ids.

**Most apps should keep real 404s.** For **sensitive** resources only, make
"forbidden" and "missing" indistinguishable:

```ruby
# Opt-in per sensitive controller / concern — not an engine default.
class SecretDocumentsController < ApplicationController
  rescue_from ActiveRecord::RecordNotFound, with: :hide
  # Later-registered handler wins for AccessDenied over the gem's rescue_from:
  rescue_from CurrentScope::AccessDenied, with: :hide

  private
  def hide
    head :not_found
  end
end
```

Cost: you lose the machine-readable 403 reason (and legitimate users may see
404 on a real denial). That indistinguishability is the point — use it only
where enumeration is a threat.

Cross-link: nil-record SoD skip when this hook returns `nil` on an SoD member
action — [README § Separation of duties](../README.md#separation-of-duties-opt-in).

---

## 3. Foot-guns (pointers)

Do not re-derive these here — full treatments live in the README:

| Foot-gun | Where |
|---|---|
| SoD member action + nil record silently skips the veto | [README § SoD](../README.md#separation-of-duties-opt-in) · report-mode diagnosis (#73) |
| `actor_method` unset under impersonation | [README § Impersonation](../README.md#impersonation-act-as) |
| Short-form `allowed_to?` key drift on namespaced controllers | [README residual foot-gun](../README.md) (namespaced / custom-named controllers) |
| Advisory `allowed_to?` never consults the catalog | Issue #36 |

---

## 4. Going to production

Tick before you ship:

- [ ] **`config.audit = :strict`** if audit is mandatory — a missing
  `current_scope_events` table then rolls the mutation back instead of
  committing unaudited. Default `true` degrades gracefully for upgrades.
- [ ] **Bootstrap a full-access admin** on the fresh prod DB before opening the
  console: `bin/rails current_scope:grant SUBJECT_ID=…` or `CurrentScope.grant!`.
  The management UI only admits full-access subjects.
- [ ] **Leave `config.enforcement = :enforce`** (or finish report-mode survey and
  flip). Report mode in production logs a boot warning for a reason — it is a
  ramp, not a posture. `rails current_scope:report` (and `access.sod_blind_spot`
  rows) only help while you are still surveying.
- [ ] **`allow_mutations_while_impersonating`** — production **raises at boot**
  unless `ENV["CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS"]` is truthy.
  Prefer leaving it false so act-as stays read-only in prod.
- [ ] **Clear act-as on sign-in and sign-out** (and skip the mutation guard on
  those actions) so a session cannot keep a foreign subject after auth churn.
- [ ] **`GatingTripwire` in dev/test** (`config.gating_tripwire = :raise` or
  `:warn`) so ungated controllers fail the suite, not production traffic.
- [ ] **Hosts on `rails-html-sanitizer` ≥ 1.7.1** (engine lock may already pin
  it; resolve your own tree).
- [ ] Read **excluded + skip** and **403/404** sections above for every
  controller that is not a normal Guard'd HTML base.

---

## Denial surface (for host 403 pages)

See also [README denial reasons](../README.md) and issue #39:

- `AccessDenied#permission`, `#reason`, `#record`, `#subject` (prefer
  `#permission` over `#message`; they match at gem raise sites but can diverge
  if a host constructs the exception with an explicit `permission:`)
- Engine registers `CurrentScope::AccessDenied` → HTTP **403** in
  `rescue_responses` only when the host has not already mapped that class
  (escaped denials are not 500s; status-only — no reason header/log)
- Guard-path denials log at INFO:
  `[CurrentScope] denied controller#action (reason) → 403` — filter if volume
  from anonymous probes is noise
