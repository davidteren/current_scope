---
title: Is it the right fit?
nav_order: 1
---

<!--
  SOURCE OF TRUTH for "when not to use CurrentScope".

  The same answer is written on three other surfaces: the README's "Is it the
  right fit?" section, and the landing page's short comparison table and its
  "Pick something else, or wait" list. The questions and the disqualifier ids
  live in assets/js/fit-chooser.js. When one of those changes, change that file
  first and carry the words to those three. test/docs_site_test.rb holds the
  seam and will fail if a disqualifier there has no counterpart on them.
-->

# Is CurrentScope the right fit?

Authorization is a decision you live with for years, so this page is written to
help you say **no** as easily as yes. It compares CurrentScope with the
libraries Rails teams actually choose between — Pundit, Action Policy,
CanCanCan, Banken and Oso — names the cases where each of the others is the
better answer, and ends with a short set of questions that point at one of them.

**The honest summary:** the others put your rules in code you deploy. Oso puts
them in a policy language. CurrentScope puts them in rows an administrator
edits. Everything below follows from that one trade.

---

## The trade, in one paragraph

Every Rails authorization library answers "may this subject do this thing?".
They differ in **where the answer lives** and **who is allowed to change it**.
Pundit, Action Policy, CanCanCan and Banken keep it in Ruby: a policy class, an
`Ability`, a loyalty. Changing what "Reviewer" means is a code change, a review
and a deploy — which is exactly right when a permission change deserves that
much ceremony. Oso moves the rules into a policy language (Polar) that can be
shared across services and languages. CurrentScope moves them into your
database: permissions are derived from your routes, a role is a row with ticked
permissions, and an administrator changes it in a mounted UI while the app is
running.

That is a real trade with real costs. Read the next two sections before the
table.

---

## Where CurrentScope earns its keep

- **Roles change often, and not by developers.** If "what Reviewer means"
  changes monthly and each change is currently a pull request, the grid is the
  whole point.
- **Access is per record, not per class.** "Editor of Project 7, and nothing on
  Project 8" is a stored grant, not a condition you re-derive in every policy.
  A model can opt into a parent chain so a role granted on a project also
  answers for that project's reports, for the actions the role ticks, including
  reports created after the grant.
- **Somebody has to be able to answer "who could approve this, and when did
  that change?"** With `config.audit` on, every scoped grant, every revoke, and
  every org-wide grant made through the management console or `CurrentScope.grant!` lands
  in an append-only ledger. Direct model writes such as `RoleAssignment.create!`
  are the exception; the configuration guide tables them.
- **A four-eyes rule that must not be negotiable.** The separation-of-duties
  veto is checked before everything else and cannot be granted around, not even
  by full access. There is one deliberate break-glass, and it takes three things
  at once: `config.allow_sod_bypass = true`, a `current_scope_sod_bypassed?`
  hook on the record, and an initiator who holds the `bypass_sod` permission.
  With auditing on, the resulting allow is written to the ledger as such.
- **You are retrofitting a live app.** Report mode downgrades **a missing
  grant** to a logged allow, so you read the list before you enforce. It is not
  an off switch: the separation-of-duties veto still refuses, and the management
  console answers to its own full-access check rather than the gate.

## Where one of the others is the better choice

- **The rule depends on the data, not the record.** "Approve only under ten
  thousand", "only during business hours", "only in the caller's region".
  Pundit, Action Policy, CanCanCan and Oso all express that directly, in Ruby or
  Polar. CurrentScope has **no vocabulary for it** — its grid is
  controller × action, and the SoD veto is the one attribute-ish rule it
  ships. Do not plan to bend it into ABAC.
- **You are not only on Rails.** One policy across several services or
  languages is what Oso is built for. CurrentScope is a Rails engine and nothing
  else. Note that Oso now means Oso Cloud, a paid hosted service: the
  open-source library was retired in 2024.
- **Your permissions are not shaped like your routes.** A right that spans many
  controllers, or one screen holding several different rights, fits a policy
  object better than a `controller#action` grid.
- **Every permission change should be a code review.** That is a legitimate
  policy, and it is an argument for Pundit or Action Policy, not against them.
- **You want the smallest possible dependency.** Pundit is a convention and a
  few hundred lines. CurrentScope brings tables, a mounted UI, an audit ledger
  and a schema guard.
- **You need it certified for production today.** CurrentScope is
  [beta](limitations.md): the last gate before 1.0 is one real application
  running report mode and then enforcing
  ([#116](https://github.com/davidteren/current_scope/issues/116)).

---

## Side by side

Read the first two rows first; the rest are consequences of them.

| | CurrentScope | Pundit | Action Policy | CanCanCan | Banken | Oso |
|---|---|---|---|---|---|---|
| **Where a rule lives** | Rows in your database | A policy class per model | A policy class, with pre-checks | One `Ability` class per user | A loyalty class per controller | Polar policy files, evaluated by a hosted service |
| **Who changes it** | An administrator, in a screen, live | A developer, then a deploy | A developer, then a deploy | A developer, then a deploy | A developer, then a deploy | A developer, or a policy deploy |
| **The permission list** | Derived from your routes | The methods you define | The rules you define | The actions and subjects you name | The methods you define | The actions you name in the policy |
| **A grant on one record** | Stored, with an audit trail | You model and query it | You model and query it | Conditions in the `Ability` | You model it | First-class relationship facts |
| **Reaching a parent record** | Opt-in declared chain, up to five hops | Hand-written in the policy | Hand-written in the policy | Nested conditions | Hand-written | Rules over the relationship graph |
| **Filtering a list** | `scope_for` returns a relation | Policy scopes | Scoping rules | Rules converted to SQL | Not its focus | Filter queries from the engine |
| **Attribute rules** ("under 10,000") | **Not expressible** | Any Ruby | Any Ruby | Conditions on attributes | Any Ruby | A core strength |
| **Who-did-what ledger** | Built in, append-only | Bring your own | Bring your own | Bring your own | Bring your own | Centralised logs in the cloud product |
| **Safe rollout on a live app** | Report mode + a starter grid | Your own instrumentation | Your own instrumentation | Your own instrumentation | Your own instrumentation | Test and simulation tooling |
| **Four-eyes rule** | Structural veto, with one explicit break-glass | A condition you write | A condition you write | A condition you write | A condition you write | A rule you write |
| **Admin UI** | Mounted, included | None | None | None | None | In the cloud product |
| **Runs where** | In your app, on your database | In your app | In your app | In your app | In your app | A service you call |
| **Last release** (2026-09-01) | 0.5.1, beta | 2.5.2, Sep 2025 | 0.7.6, Jan 2026 | 3.6.1, May 2024 | 1.0.3, Jan 2019 | Ruby gem retired Jan 2024 |

*Written from the shape of each library rather than a feature audit of its
latest release.* The release row is the one thing here that goes stale on its
own, so it is dated; check RubyGems before you decide. Two entries need a word
of warning rather than a column: **Banken** has had no release since 2019, and
**Oso's** open-source library, the `oso-oso` gem included, is
[deprecated](https://github.com/osohq/oso) in favour of Oso Cloud, so choosing
Oso today means paying for a hosted service, not adding a gem. If something
here is out of date, please
[open an issue](https://github.com/davidteren/current_scope/issues) — a
comparison that flatters the author is worth nothing.

---

## Which one fits you?

Answer seven questions. Nothing is sent anywhere: this runs in your browser, and
the shorter table below works with JavaScript off.

<div id="fitter" data-fitter role="group" aria-label="Which library fits you">
  <noscript><p><em>The guided version needs JavaScript. The table below is a shorter version of the same decision.</em></p></noscript>
</div>

### A shorter version, as a table

| If this is true of you | Then |
|---|---|
| Rules depend on record attributes or time, and you cannot express them as roles | **Action Policy** (or Pundit), or **Oso** for the richest rules |
| You need one policy across services or languages | **Oso** |
| Non-developers must change permissions without a deploy | **CurrentScope** |
| You need per-record grants, an audit trail and a four-eyes rule out of the box | **CurrentScope** |
| You want the smallest, most conventional Rails dependency | **Pundit** |
| You want policy objects with caching, testing and failure reasons built in | **Action Policy** |
| You already think in `can :read, Post` and want list filtering from the same rules | **CanCanCan** |
| Your authorization is per controller, not per model, and you want it tiny | **Banken**, but read the maintenance note above the table first |
| You cannot ship anything that is still in beta, or anything pre-1.0 | Not CurrentScope, and not **Action Policy** either: it is mature and widely used but has never cut a 1.0 (0.7.6 today) |

---

## If it fits: what adopting it actually costs

Honest estimates, from the shape of the work rather than a promise.

### Greenfield, or an app with no users yet

**Half a day to a day.** There is nothing to retrofit and no traffic to break.
Install, run the generator, migrate, bootstrap the first admin, tick the grid,
and gate your controllers. The
[quickstart](quickstart.md) is the whole path.

### An existing app with users

Plan this in four stages. The long pole is **stage 2**, and it is calendar time,
not developer time.

1. **Install and record (a day).** Add the gem, run migrations, set
   `config.enforcement = :report` and `config.audit = true`. A request that
   would have been refused **for want of a grant** is allowed through and
   written to the ledger instead. Read that as "no big-bang cutover", not as
   "nothing is refused": the separation-of-duties veto, the management
   console's own full-access check, a mis-declared record hook and the
   impersonation gate are outside this setting and still refuse. A request
   with no signed-in subject is let through and recorded nowhere, which is why
   sign-in has to be skipped explicitly (below).
2. **Bake (one to four weeks).** Let real traffic run. Month-end, quarter-end
   and the annual job matter here: an action nobody performs during your bake is
   an action nobody has granted, and it will fail the day someone runs it.
3. **Build the grid (a day or two).** `bin/rails current_scope:report` prints
   what each subject was refused and still needs. It creates no roles: you read
   the list, design the roles yourself, tick the grid, assign, re-run, and
   repeat until the report is empty. The work it saves is finding out what is
   missing, not deciding what a role should mean.
4. **Enforce (an hour, plus a watchful week).** Flip to `:enforce`. Keep the
   ledger on; it is now your record of who was refused what.

### What makes it slower

- **Routes that are not permissions.** Health checks, webhooks and sign-in must
  be skipped explicitly, or the gate locks out the very requests that establish
  a subject.
- **Actions your bake never saw.** See stage 2. This is the single most common
  reason a flip goes badly.
- **A subject that is not a simple `id`.** UUIDs and composite identities are
  supported, but `config.subject_identity` is a decision to make deliberately.
- **Rules you thought were roles.** If a third of your `if` statements turn out
  to depend on amounts or dates, that is the signal from the section above:
  you needed a policy library, not a role grid.

---

## Still deciding?

- Read [Limitations](limitations.md) — it is the least flattering page on this
  site, on purpose.
- Read [Concepts](concepts.md) for the resolver order that decides every
  request.
- Install it in a branch, run report mode for a week, and look at what the
  report says. That costs a day and tells you more than any comparison table.

<style>
  /* Scoped to the fit-finder; the theme owns everything else on this page. */
  [data-fitter] { margin: 1.5rem 0 2rem; }
  .cs-fit {
    border: 1px solid rgba(128, 145, 150, .35);
    border-radius: 6px;
    padding: 1.1rem 1.2rem 1.25rem;
  }
  .cs-fit-step { font-size: .78rem; letter-spacing: .1em; text-transform: uppercase; opacity: .7; }
  .cs-fit-q { font-size: 1.15rem; font-weight: 600; margin: .35rem 0 1rem; line-height: 1.3; }
  .cs-fit-opts { display: flex; flex-wrap: wrap; gap: .5rem; }
  .cs-fit-opts button,
  .cs-fit-nav button {
    font: inherit;
    font-size: .95rem;
    padding: .5rem .9rem;
    border-radius: 5px;
    border: 1px solid rgba(128, 145, 150, .5);
    background: transparent;
    color: inherit;
    cursor: pointer;
  }
  .cs-fit-opts button:hover,
  .cs-fit-nav button:hover { border-color: currentColor; }
  .cs-fit-opts button:focus-visible,
  .cs-fit-nav button:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
  /* Secondary to the answers: same shape, quieter. */
  .cs-fit-nav { margin-top: .9rem; }
  .cs-fit-nav button { font-size: .85rem; padding: .35rem .7rem; opacity: .8; }
  .cs-fit-nav button:hover { opacity: 1; }
  .cs-fit-bar { height: 3px; background: rgba(128, 145, 150, .25); border-radius: 3px; margin-bottom: 1rem; overflow: hidden; }
  .cs-fit-bar i { display: block; height: 100%; background: currentColor; opacity: .55; transition: width .2s ease; }
  .cs-fit-verdict h3 { margin: .2rem 0 .6rem; font-size: 1.25rem; }
  .cs-fit-why { margin: 0 0 1rem; padding-left: 1.1rem; }
  .cs-fit-why li { margin-bottom: .35rem; }
  @media (prefers-reduced-motion: reduce) { .cs-fit-bar i { transition: none; } }
</style>

<script src="{{ '/assets/js/fit-chooser.js' | relative_url }}"></script>
