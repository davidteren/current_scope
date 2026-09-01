---
title: Is it the right fit?
nav_order: 1
---

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
  A model can opt into a parent chain so a grant on a project covers that
  project's reports, including reports created after the grant.
- **Somebody has to be able to answer "who could approve this, and when did
  that change?"** Every grant and revoke lands in an append-only ledger.
- **A four-eyes rule that must not be negotiable.** The separation-of-duties
  veto is checked before everything else and cannot be granted around, not even
  by full access.
- **You are retrofitting a live app.** Report mode decides nothing and records
  every request it *would* have refused, so you read the list before you
  enforce.

## Where one of the others is the better choice

- **The rule depends on the data, not the record.** "Approve only under ten
  thousand", "only during business hours", "only in the caller's region".
  Pundit, Action Policy, CanCanCan and Oso all express that directly, in Ruby or
  Polar. CurrentScope has **no vocabulary for it** — its grid is
  controller × action, and the SoD veto is the one attribute-ish rule it
  ships. Do not plan to bend it into ABAC.
- **You are not only on Rails.** One policy across several services or
  languages is what Oso is built for. CurrentScope is a Rails engine and nothing
  else.
- **Your permissions are not shaped like your routes.** A right that spans many
  controllers, or one screen holding several different rights, fits a policy
  object better than a `controller#action` grid.
- **Every permission change should be a code review.** That is a legitimate
  policy, and it is an argument for Pundit or Action Policy, not against them.
- **You want the smallest possible dependency.** Pundit is a convention and a
  few hundred lines. CurrentScope brings tables, a mounted UI, an audit ledger
  and a schema guard.
- **You need it certified for production today.** CurrentScope is
  [beta](limitations.html): the last gate before 1.0 is one real application
  running report mode and then enforcing
  ([#116](https://github.com/davidteren/current_scope/issues/116)).

---

## Side by side

Read the first two rows first; the rest are consequences of them.

| | CurrentScope | Pundit | Action Policy | CanCanCan | Banken | Oso |
|---|---|---|---|---|---|---|
| **Where a rule lives** | Rows in your database | A policy class per model | A policy class, with pre-checks | One `Ability` class per user | A loyalty class per controller | Polar policy files, or a hosted service |
| **Who changes it** | An administrator, in a screen, live | A developer, then a deploy | A developer, then a deploy | A developer, then a deploy | A developer, then a deploy | A developer, or a policy deploy |
| **The permission list** | Derived from your routes | The methods you define | The rules you define | The actions and subjects you name | The methods you define | The actions you name in the policy |
| **A grant on one record** | Stored, with an audit trail | You model and query it | You model and query it | Conditions in the `Ability` | You model it | First-class relationship facts |
| **Reaching a parent record** | Opt-in declared chain, up to five hops | Hand-written in the policy | Hand-written in the policy | Nested conditions | Hand-written | Rules over the relationship graph |
| **Filtering a list** | `scope_for` returns a relation | Policy scopes | Scoping rules | Rules converted to SQL | Not its focus | Filter queries from the engine |
| **Attribute rules** ("under R10,000") | **Not expressible** | Any Ruby | Any Ruby | Conditions on attributes | Any Ruby | A core strength |
| **Who-did-what ledger** | Built in, append-only | Bring your own | Bring your own | Bring your own | Bring your own | Centralised logs in the cloud product |
| **Safe rollout on a live app** | Report mode + a starter grid | Your own instrumentation | Your own instrumentation | Your own instrumentation | Your own instrumentation | Test and simulation tooling |
| **Four-eyes rule** | Structural: not grantable around | A condition you write | A condition you write | A condition you write | A condition you write | A rule you write |
| **Admin UI** | Mounted, included | None | None | None | None | In the cloud product |
| **Runs where** | In your app, on your database | In your app | In your app | In your app | In your app | In your app, or a service you call |

*Written from the shape of each library rather than a feature audit of its
latest release.* If something here is out of date, please
[open an issue](https://github.com/davidteren/current_scope/issues) — a
comparison that flatters the author is worth nothing.

---

## Which one fits you?

Answer five questions. Nothing is sent anywhere: this runs in your browser, and
the plain-text version below works with JavaScript off.

<div id="fitter" data-fitter role="group" aria-live="polite" aria-label="Which library fits you">
  <noscript><p><em>The guided version needs JavaScript. The decision table below says the same thing.</em></p></noscript>
</div>

### The same thing, as a table

| If this is true of you | Then |
|---|---|
| Rules depend on record attributes or time, and you cannot express them as roles | **Action Policy** (or Pundit), or **Oso** for the richest rules |
| You need one policy across services or languages | **Oso** |
| Non-developers must change permissions without a deploy | **CurrentScope** |
| You need per-record grants, an audit trail and a four-eyes rule out of the box | **CurrentScope** |
| You want the smallest, most conventional Rails dependency | **Pundit** |
| You want policy objects with caching, testing and failure reasons built in | **Action Policy** |
| You already think in `can :read, Post` and want list filtering from the same rules | **CanCanCan** |
| Your authorization is per controller, not per model, and you want it tiny | **Banken** |
| You cannot ship anything that is still in beta | Not CurrentScope, yet |

---

## If it fits: what adopting it actually costs

Honest estimates, from the shape of the work rather than a promise.

### Greenfield, or an app with no users yet

**Half a day to a day.** There is nothing to retrofit and no traffic to break.
Install, run the generator, migrate, bootstrap the first admin, tick the grid,
and gate your controllers. The
[quickstart](quickstart.html) is the whole path.

### An existing app with users

Plan this in four stages. The long pole is **stage 2**, and it is calendar time,
not developer time.

1. **Install and record (a day).** Add the gem, run migrations, set
   `config.enforcement = :report` and `config.audit = true`. Nothing is refused;
   every request that *would* have been refused is written to the ledger.
2. **Bake (one to four weeks).** Let real traffic run. Month-end, quarter-end
   and the annual job matter here: an action nobody performs during your bake is
   an action nobody has granted, and it will fail the day someone runs it.
3. **Build the grid (a day or two).** `bin/rails current_scope:report` turns the
   recorded denials into a starter set of roles. Tick, assign, re-run, repeat
   until the report is empty.
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

- Read [Limitations](limitations.html) — it is the least flattering page on this
  site, on purpose.
- Read [Concepts](concepts.html) for the resolver order that decides every
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
  .cs-fit-opts button {
    font: inherit;
    font-size: .95rem;
    padding: .5rem .9rem;
    border-radius: 5px;
    border: 1px solid rgba(128, 145, 150, .5);
    background: transparent;
    color: inherit;
    cursor: pointer;
  }
  .cs-fit-opts button:hover { border-color: currentColor; }
  .cs-fit-opts button:focus-visible { outline: 2px solid currentColor; outline-offset: 2px; }
  .cs-fit-bar { height: 3px; background: rgba(128, 145, 150, .25); border-radius: 3px; margin-bottom: 1rem; overflow: hidden; }
  .cs-fit-bar i { display: block; height: 100%; background: currentColor; opacity: .55; transition: width .2s ease; }
  .cs-fit-verdict h4 { margin: .2rem 0 .6rem; font-size: 1.25rem; }
  .cs-fit-why { margin: 0 0 1rem; padding-left: 1.1rem; }
  .cs-fit-why li { margin-bottom: .35rem; }
  .cs-fit-restart { font-size: .9rem; }
  @media (prefers-reduced-motion: reduce) { .cs-fit-bar i { transition: none; } }
</style>

<script>
(function () {
  var mount = document.querySelector("[data-fitter]");
  if (!mount) return;

  // Each answer adds points to one or more libraries, and can set a hard
  // disqualifier. Order matters: the disqualifiers are asked first, so a reader
  // who should not use CurrentScope learns it on question one or two.
  var QUESTIONS = [
    {
      q: "Do any of your access rules depend on the record's data or the time — an amount, a date, a region, a status?",
      opts: [
        { label: "Yes, several", score: { pundit: 2, action_policy: 3, cancancan: 2, oso: 3 }, veto: "attributes" },
        { label: "One or two, at the edges", score: { action_policy: 2, oso: 1, current_scope: 1 } },
        { label: "No — access follows who someone is, and which records they hold", score: { current_scope: 3, cancancan: 1 } }
      ]
    },
    {
      q: "Does anything other than a Rails app need the same answer — another service, another language?",
      opts: [
        { label: "Yes", score: { oso: 4 }, veto: "polyglot" },
        { label: "No, one Rails app", score: { current_scope: 2, pundit: 1, action_policy: 1, cancancan: 1, banken: 1 } }
      ]
    },
    {
      q: "Who should be able to change what a role means?",
      opts: [
        { label: "An administrator, in a screen, without a deploy", score: { current_scope: 4 } },
        { label: "A developer, through code review", score: { pundit: 2, action_policy: 2, cancancan: 2, banken: 2 } },
        { label: "Either is fine", score: { current_scope: 1, action_policy: 1 } }
      ]
    },
    {
      q: "Do people get access to individual records — this project, that client — rather than to whole classes of thing?",
      opts: [
        { label: "Yes, constantly", score: { current_scope: 3, oso: 2 } },
        { label: "Sometimes", score: { current_scope: 1, cancancan: 1, action_policy: 1 } },
        { label: "No, access is the same across all records of a type", score: { pundit: 2, action_policy: 2, banken: 1 } }
      ]
    },
    {
      q: "Do you need an audit trail of who granted what, and a rule that stops the author of a record approving it?",
      opts: [
        { label: "Yes, both — we are audited", score: { current_scope: 4 } },
        { label: "The audit trail, at least", score: { current_scope: 2 } },
        { label: "Neither", score: { pundit: 1, action_policy: 1, cancancan: 1, banken: 1 } }
      ]
    }
  ];

  var LIBS = {
    current_scope: {
      name: "CurrentScope",
      line: "Roles as data an administrator edits, per-record grants, an audit ledger and a report-mode rollout.",
      href: "quickstart.html",
      cta: "Read the quickstart"
    },
    pundit: {
      name: "Pundit",
      line: "The smallest, most conventional choice: a plain policy class per model, and nothing else to run.",
      href: "https://github.com/varvet/pundit",
      cta: "Pundit on GitHub"
    },
    action_policy: {
      name: "Action Policy",
      line: "Policy objects with pre-checks, caching, failure reasons and testing tools — policies as a first-class layer.",
      href: "https://actionpolicy.evilmartians.io/",
      cta: "Action Policy docs"
    },
    cancancan: {
      name: "CanCanCan",
      line: "One Ability per user, declared as data your app can also turn into SQL for filtering lists.",
      href: "https://github.com/CanCanCommunity/cancancan",
      cta: "CanCanCan on GitHub"
    },
    banken: {
      name: "Banken",
      line: "Pundit's shape, but per controller rather than per model, and deliberately tiny.",
      href: "https://github.com/Kanety/banken",
      cta: "Banken on GitHub"
    },
    oso: {
      name: "Oso",
      line: "A policy language of its own, built for rich rules and for one answer shared across services.",
      href: "https://www.osohq.com/",
      cta: "Oso"
    }
  };

  var VETO_NOTE = {
    attributes:
      "You said several rules depend on the record's data or the time. CurrentScope cannot express those: its grid is controller and action, and roles do not carry conditions.",
    polyglot:
      "You said something outside Rails needs the same answer. CurrentScope is a Rails engine, so it can only speak for the Rails app."
  };

  var state = { i: 0, score: {}, vetoes: [] };

  function render() {
    if (state.i >= QUESTIONS.length) return renderVerdict();
    var q = QUESTIONS[state.i];
    var el = document.createElement("div");
    el.className = "cs-fit";
    el.innerHTML =
      '<div class="cs-fit-bar"><i style="width:' + Math.round((state.i / QUESTIONS.length) * 100) + '%"></i></div>' +
      '<div class="cs-fit-step">Question ' + (state.i + 1) + " of " + QUESTIONS.length + "</div>" +
      '<p class="cs-fit-q" data-focus></p><div class="cs-fit-opts"></div>';
    el.querySelector(".cs-fit-q").textContent = q.q;

    var opts = el.querySelector(".cs-fit-opts");
    q.opts.forEach(function (opt) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = opt.label;
      b.addEventListener("click", function () {
        Object.keys(opt.score || {}).forEach(function (k) {
          state.score[k] = (state.score[k] || 0) + opt.score[k];
        });
        if (opt.veto) state.vetoes.push(opt.veto);
        state.i += 1;
        render();
      });
      opts.appendChild(b);
    });

    swapIn(el);
  }

  // The activated button is destroyed by its own click, so focus falls to the
  // body unless we move it. The new heading takes it, which also makes the
  // live region announce the question rather than nothing.
  function swapIn(el, focusFirst) {
    var hadFocus = mount.contains(document.activeElement);
    mount.innerHTML = "";
    mount.appendChild(el);
    if (!hadFocus) return;
    var target = focusFirst || el.querySelector("[data-focus]") || el;
    if (!target.hasAttribute("tabindex")) target.setAttribute("tabindex", "-1");
    target.focus();
  }

  function renderVerdict() {
    var ranked = Object.keys(LIBS)
      .map(function (k) { return { key: k, n: state.score[k] || 0 }; })
      .sort(function (a, b) { return b.n - a.n; });

    // A veto removes CurrentScope from the running, whatever it scored: the
    // point of this page is to let someone say no early.
    if (state.vetoes.length) {
      ranked = ranked.filter(function (r) { return r.key !== "current_scope"; });
    }

    var top = LIBS[ranked[0].key];
    var runnerUp = ranked[1] && ranked[1].n > 0 ? LIBS[ranked[1].key] : null;

    var el = document.createElement("div");
    el.className = "cs-fit cs-fit-verdict";
    var html =
      '<div class="cs-fit-step">Based on your answers</div>' +
      "<h4>" + top.name + "</h4>" +
      "<p>" + top.line + "</p>";

    if (state.vetoes.length) {
      html += '<ul class="cs-fit-why">';
      state.vetoes.forEach(function (v) { html += "<li>" + VETO_NOTE[v] + "</li>"; });
      html += "</ul>";
    }

    if (runnerUp) {
      html += "<p>Worth a look as well: <strong>" + runnerUp.name + "</strong> — " + runnerUp.line + "</p>";
    }

    html +=
      '<p><a href="' + top.href + '">' + top.cta + "</a></p>" +
      '<p class="cs-fit-restart"><button type="button" data-restart>Start again</button></p>';

    el.innerHTML = html;
    el.querySelector("[data-restart]").addEventListener("click", function () {
      state = { i: 0, score: {}, vetoes: [] };
      render();
    });

    swapIn(el, el.querySelector("h4"));
  }

  render();
})();
</script>
