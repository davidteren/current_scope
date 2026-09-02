---
title: Is it the right fit?
nav_order: 1
---

<!--
  SOURCE OF TRUTH for "when not to use CurrentScope".

  The same answer is written on three other surfaces: the README's "Is it the
  right fit?" section, and the landing page's short comparison table and its
  "Pick something else, or wait" list. When the answer changes, change it here
  first and carry it to those three. test/docs_site_test.rb holds the seam and
  will fail if a disqualifier here has no counterpart there.
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
  [beta](limitations.html): the last gate before 1.0 is one real application
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
| **Four-eyes rule** | Structural: not grantable around | A condition you write | A condition you write | A condition you write | A condition you write | A rule you write |
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

Answer six questions. Nothing is sent anywhere: this runs in your browser, and
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

<script>
(function () {
  var mount = document.querySelector("[data-fitter]");
  if (!mount) return;

  // Each answer adds points to one or more libraries, and can set a hard
  // disqualifier that no score can outweigh. The two that most often rule
  // CurrentScope out are asked first, so a reader who should not use it learns
  // that on question one or two rather than at the end. The beta question is
  // last on purpose: see the comment above it.
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
        { label: "No, one Rails app", score: { current_scope: 2, pundit: 1, action_policy: 1, cancancan: 1 } }
      ]
    },
    {
      q: "Who should be able to change what a role means?",
      opts: [
        { label: "An administrator, in a screen, without a deploy", score: { current_scope: 4 } },
        // A veto, not just points. Both this page and the README list "every
        // permission change should be a code review" as a reason to choose
        // something else, and it is the exact premise CurrentScope inverts. A
        // high score elsewhere used to override the reader saying so.
        { label: "A developer, through code review", score: { pundit: 2, action_policy: 2, cancancan: 2 },
          veto: "code_review" },
        { label: "Either is fine", score: { current_scope: 1, action_policy: 1 } }
      ]
    },
    {
      q: "Do people get access to individual records — this project, that client — rather than to whole classes of thing?",
      opts: [
        { label: "Yes, constantly", score: { current_scope: 3, oso: 2 } },
        { label: "Sometimes", score: { current_scope: 1, cancancan: 1, action_policy: 1 } },
        { label: "No, access is the same across all records of a type", score: { pundit: 2, action_policy: 2 } }
      ]
    },
    {
      q: "Do you need an audit trail of who granted what, and a rule that stops the author of a record approving it?",
      opts: [
        { label: "Yes, both — we are audited", score: { current_scope: 4 } },
        { label: "The audit trail, at least", score: { current_scope: 2 } },
        { label: "Neither", score: { pundit: 1, action_policy: 1, cancancan: 1 } }
      ]
    },
    // CurrentScope's own headline disqualifier. It was in the table and not in
    // the questions, so a reader who cannot ship beta software could be walked
    // through the whole thing and handed CurrentScope at the end.
    //
    // Last, not first: it asks about this project's maturity rather than the
    // shape of the reader's app, so it cannot help choose between the others.
    // Asked first it would read as an apology before a single question.
    {
      q: "Can you put software that is still in beta into production?",
      opts: [
        { label: "No — it has to be 1.0 or later", score: { pundit: 2, action_policy: 2, cancancan: 2 }, veto: "beta" },
        { label: "Yes, with our eyes open", score: { current_scope: 1 } }
      ]
    }
  ];

  // Every entry carries what you give up by choosing it, and the verdict always
  // prints it. A recommendation that names only the upside is the flattering
  // kind this page exists to avoid.
  //
  // Banken is deliberately absent. It is in the table above, but it has had no
  // release since 2019, and a guided answer that points a reader at a dormant
  // gem is worse advice than a table row they can weigh for themselves.
  var LIBS = {
    current_scope: {
      name: "CurrentScope",
      line: "Roles as data an administrator edits, per-record grants, an audit ledger and a report-mode rollout.",
      givesUp: "Any rule that depends on an amount, a date or a status has to live in your own application code: the grid is controller and action. It is also still in beta.",
      href: "quickstart.html",
      cta: "Read the quickstart"
    },
    pundit: {
      name: "Pundit",
      line: "The smallest, most conventional choice: a plain policy class per model, and nothing else to run.",
      givesUp: "There is no admin screen, no audit trail and no per-record grant store. You write and maintain each of those yourself.",
      href: "https://github.com/varvet/pundit",
      cta: "Pundit on GitHub"
    },
    action_policy: {
      name: "Action Policy",
      line: "Policy objects with pre-checks, caching, failure reasons and testing tools — policies as a first-class layer.",
      givesUp: "Changing what a role means is still a code change, a review and a deploy. No admin screen, no ledger.",
      href: "https://actionpolicy.evilmartians.io/",
      cta: "Action Policy docs"
    },
    cancancan: {
      name: "CanCanCan",
      line: "One Ability per user, declared as data your app can also turn into SQL for filtering lists.",
      givesUp: "The single Ability class grows with the app and is the usual complaint about it. No admin screen, no ledger.",
      href: "https://github.com/CanCanCommunity/cancancan",
      cta: "CanCanCan on GitHub"
    },
    oso: {
      name: "Oso Cloud",
      line: "A policy language of its own, built for rich rules and for one answer shared across services and languages.",
      givesUp: "The open-source library was retired in 2024, so this is a paid hosted service your app calls, and one more thing that has to be up for a request to be authorized.",
      href: "https://www.osohq.com/",
      cta: "Oso Cloud"
    }
  };

  // A veto is a requirement no score can outweigh, so it removes every library
  // that cannot meet it — not just this one's. Saying "another language needs
  // the same answer" and then being handed a Rails-only gem is the failure this
  // shape prevents.
  var VETOES = {
    attributes: {
      note: "You said several rules depend on the record's data or the time. CurrentScope cannot express those: its grid is controller and action, and roles do not carry conditions.",
      removes: ["current_scope"]
    },
    polyglot: {
      note: "You said something outside Rails needs the same answer. That rules out every Rails-only library here, CurrentScope included.",
      removes: ["current_scope", "pundit", "action_policy", "cancancan"]
    },
    code_review: {
      note: "You said a permission change should go through code review. That is exactly what CurrentScope removes: a role is a row an administrator edits while the app is running.",
      removes: ["current_scope"]
    },
    beta: {
      note: "You said production needs 1.0 or later. CurrentScope is still in beta: the last gate before 1.0 is one real application running report mode and then enforcing.",
      removes: ["current_scope"]
    }
  };

  function fresh() { return { i: 0, score: {}, vetoes: [] }; }

  var state = fresh();
  // One snapshot per answer, so a mis-click costs one click to undo rather than
  // a page reload. Undoing by subtracting the answer's points back out would
  // have to stay in step with the scoring forever; a snapshot cannot drift.
  var history = [];

  function snapshot() {
    var score = {};
    Object.keys(state.score).forEach(function (k) { score[k] = state.score[k]; });
    return { i: state.i, score: score, vetoes: state.vetoes.slice() };
  }

  function restart() {
    state = fresh();
    history = [];
    render();
  }

  // The same two buttons appear on a question, on the verdict, and on the
  // "none of these" verdict. Built and wired in one place so a change to how
  // Back restores state cannot be applied to two of the three.
  var NAV_HTML =
    '<p class="cs-fit-nav"><button type="button" data-back>Back</button> ' +
    '<button type="button" data-restart>Start again</button></p>';

  function wireNav(el) {
    var back = el.querySelector("[data-back]");
    if (back) {
      back.addEventListener("click", function () {
        if (!history.length) return restart();
        state = history.pop();
        render();
      });
    }
    var again = el.querySelector("[data-restart]");
    if (again) again.addEventListener("click", restart);
  }

  function render() {
    if (state.i >= QUESTIONS.length) return renderVerdict();
    var q = QUESTIONS[state.i];
    var el = document.createElement("div");
    el.className = "cs-fit";
    el.innerHTML =
      '<div class="cs-fit-bar"><i style="width:' + Math.round((state.i / QUESTIONS.length) * 100) + '%"></i></div>' +
      '<div class="cs-fit-step">Question ' + (state.i + 1) + " of " + QUESTIONS.length + "</div>" +
      '<p class="cs-fit-q" data-focus></p><div class="cs-fit-opts"></div>' +
      (history.length ? NAV_HTML : "");
    el.querySelector(".cs-fit-q").textContent = q.q;

    wireNav(el);

    var opts = el.querySelector(".cs-fit-opts");
    q.opts.forEach(function (opt) {
      var b = document.createElement("button");
      b.type = "button";
      b.textContent = opt.label;
      b.addEventListener("click", function () {
        history.push(snapshot());
        Object.keys(opt.score || {}).forEach(function (k) {
          state.score[k] = (state.score[k] || 0) + opt.score[k];
        });
        if (opt.veto) state.vetoes.push(opt.veto);
        state.i += 1;
        answered = true; // from here on, every swap announces itself
        render();
      });
      opts.appendChild(b);
    });

    swapIn(el);
  }

  // The activated button is destroyed by its own click, so focus falls to the
  // body unless we move it. The new question takes it, and a screen reader
  // announces it on focus. There is deliberately no aria-live on the container:
  // with the focus move in place it would announce every question twice.
  //
  // `answered` rather than checking document.activeElement: Safari and Firefox
  // on macOS do not focus a <button> on a mouse click, so an activeElement test
  // reads as "the reader was never here" and the announcement never happens for
  // pointer users on those browsers. What matters is that the reader answered,
  // not which input device told us.
  var answered = false;

  function swapIn(el, focusFirst) {
    mount.innerHTML = "";
    mount.appendChild(el);
    if (!answered) return;
    var target = focusFirst || el.querySelector("[data-focus]") || el;
    if (!target.hasAttribute("tabindex")) target.setAttribute("tabindex", "-1");
    target.focus();
  }

  function renderVerdict() {
    var out = {};
    state.vetoes.forEach(function (v) {
      VETOES[v].removes.forEach(function (k) { out[k] = true; });
    });

    var ranked = Object.keys(LIBS)
      .filter(function (k) { return !out[k]; })
      .map(function (k) { return { key: k, n: state.score[k] || 0 }; })
      .sort(function (a, b) { return b.n - a.n; });

    // No veto combination empties this today, but a future one could, and a
    // throw here would freeze the chooser on the last question with nothing on
    // screen. Say the honest thing instead.
    if (!ranked.length) {
      var none = document.createElement("div");
      none.className = "cs-fit cs-fit-verdict";
      none.innerHTML = '<div class="cs-fit-step">Based on your answers</div>' +
        "<h3>None of these</h3><p>Your answers rule out every library on this page. " +
        "The table above is the place to start instead.</p>" +
        NAV_HTML;
      wireNav(none);
      return swapIn(none, none.querySelector("h3"));
    }

    // Every library that scored the top score, not just the first two. The
    // scores are coarse on purpose, so ties are common; naming one of them the
    // answer would only report the order this object literal is written in.
    var winners = ranked.filter(function (r) { return r.n === ranked[0].n; })
      .map(function (r) { return LIBS[r.key]; });
    // Second place gets the same treatment as first. Taking ranked[n] alone
    // would resolve a tie for second by declaration order, and CurrentScope is
    // declared first, so the bias the winners avoid would come back here.
    var next = ranked[winners.length];
    var seconds = !next || next.n <= 0 ? [] :
      ranked.filter(function (r) { return r.n === next.n; }).map(function (r) { return LIBS[r.key]; });

    var names = winners.map(function (l) { return l.name; });
    var heading = names.length === 1
      ? names[0]
      : names.slice(0, -1).join(", ") + " or " + names[names.length - 1];

    var el = document.createElement("div");
    el.className = "cs-fit cs-fit-verdict";
    var html =
      '<div class="cs-fit-step">Based on your answers</div>' +
      "<h3>" + heading + "</h3>";

    winners.forEach(function (l) {
      html += "<p>" + (winners.length > 1 ? "<strong>" + l.name + "</strong> — " : "") + l.line + "</p>";
    });
    if (winners.length > 1) {
      html += "<p>Your answers fit " + (winners.length === 2 ? "these two" : "all " + winners.length) +
        " equally well. Read them side by side.</p>";
    }

    if (state.vetoes.length) {
      html += '<ul class="cs-fit-why">';
      state.vetoes.forEach(function (v) { html += "<li>" + VETOES[v].note + "</li>"; });
      html += "</ul>";
    }

    winners.forEach(function (l) {
      html += "<p><strong>What you give up with " + l.name + ":</strong> " + l.givesUp + "</p>";
    });

    // A runner-up is a recommendation too, so it carries its cost like the
    // winners do. Naming only the upside is the flattering kind.
    seconds.forEach(function (l) {
      html += "<p>Worth a look as well: <strong>" + l.name + "</strong> — " + l.line +
        " <em>" + l.givesUp + "</em></p>";
    });

    html += "<p>" + winners.map(function (l) {
      return '<a href="' + l.href + '">' + l.cta + "</a>";
    }).join(" &middot; ") + "</p>" +
      NAV_HTML;

    el.innerHTML = html;
    // Back from the verdict returns to the last question, so a reader who wants
    // to see what one different answer would have said does not start over.
    wireNav(el);

    swapIn(el, el.querySelector("h3"));
  }

  render();
})();
</script>
