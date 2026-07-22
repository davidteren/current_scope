---
title: Concepts
nav_order: 3
---

# Concepts

Authorization as data you edit in a UI, not rules you hardcode and redeploy.
Five ideas carry the whole engine.

## Permissions are your routes

Every `controller#action` pair *is* a permission. Add an `OrdersController`
and its actions appear in the permission grid with zero wiring. There is no
policy file to write and no permission constant to register — the catalog is
derived from what your app actually routes, so it cannot drift from the code.

## Roles are rows, not classes

A role is a named, editable bundle of permissions — ticked cells on a
controller × action grid in the mounted management UI. Changing what
"Reviewer" means is an edit, not a deploy. Granting a key the app doesn't
route makes the role invalid (naming the key), so a typo is an error at save
time, not an unexplained 403 later.

## Scoped roles bind a role to one record

The same role, attached to one specific record: "Editor of Project #7"
grants nothing on Project #8. The list-side companion is `scope_for` — it
answers "*which* records may I act on?" from the same roles and grants the
gate reads, so an index page and the per-record gate stay one source of
truth.

## The resolver order is fixed

Every check — the controller gate, a view helper, a ViewComponent — asks the
same resolver, which answers in this order:

```
1. SoD veto        → initiator? (opt-in, off by default)  DENY (overrides all)
2. full_access     → role grants everything, forever      ALLOW
3. org-wide role   → role's permission set includes it    ALLOW
4. scoped role     → a role held on THIS record           ALLOW
5. otherwise       → default deny
```

Two things to notice. The [separation-of-duties veto](separation-of-duties.md)
outranks `full_access` — an admin cannot self-approve. And the last line is
the posture: **no grant means denied**. Everything is a permission, even the
baseline things every signed-in user can do.

## One ambient context

The current subject flows through `ActiveSupport::CurrentAttributes` from
the controller gate down to the smallest ViewComponent — no `current_user`
threading, ever:

```ruby
allowed_to?(:approve, report)         # key derived from the record → reports#approve
allowed_to?(:create, Report)          # class form for collection actions
allowed_to?("admin/reports#approve")  # explicit key when you need it
```

Controller, view, and component ask the same resolver.
`CurrentAttributes` resets around every request, job, and test, so the
ambient subject cannot leak between executions.

**The honest caveat:** the short form's key derivation matches the gate only
when the controller's path segment ends in the record's route key. In a
controller whose path differs from the record's route key (a
`DashboardController` rendering `Report`s), prefer the explicit full key —
`allowed_to?("dashboard#show")`. The Guard stays authoritative either way,
so a mismatch is a display bug, not a bypass. Details in the
[README](https://github.com/davidteren/current_scope/blob/main/README.md#checking-permissions--anywhere).

## Where the deep answers live

The [README](https://github.com/davidteren/current_scope/blob/main/README.md)
is the canonical reference: `scope_for` semantics, record hooks,
impersonation and the read-only mutation guard, the audit ledger, dev
diagnostics, and testing helpers.
