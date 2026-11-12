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
        { label: "An administrator, in a screen, without a deploy", score: { current_scope: 4, oso: 1 } },
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
        { label: "Yes, both — we are audited", score: { current_scope: 4, oso: 1 } },
        { label: "The audit trail, at least", score: { current_scope: 2, oso: 1 } },
        { label: "Neither", score: { pundit: 1, action_policy: 1, cancancan: 1 } }
      ]
    },
    // Pundit was weakly dominated before this: Action Policy scored at least as
    // well on every option of every question, so Pundit could only ever tie and
    // never be the answer, while the table below promised it to exactly this
    // reader. Nothing asked about footprint, so nothing could send them there.
    {
      q: "How much are you willing to add to the application?",
      opts: [
        // A veto for the same reason the polyglot answer is one: this rules two
        // libraries out rather than merely preferring the others. Without it a
        // reader who asked for one Rails app and the smallest possible
        // dependency could be handed Oso Cloud, a paid service their app calls
        // over the network, because nothing ever subtracted from its score.
        { label: "As little as possible — a convention and a few hundred lines", score: { pundit: 4 },
          veto: "minimal_footprint" },
        { label: "A policy layer with its own tooling is fine", score: { action_policy: 2, cancancan: 2 } },
        { label: "Tables, a mounted UI and a migration are fine", score: { current_scope: 2, oso: 1 } }
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
        { label: "No — it has to be 1.0 or later", score: { pundit: 2, cancancan: 2 }, veto: "beta" },
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
      // .html, unlike the Markdown links on this page: jekyll-relative-links
      // rewrites link syntax, not a string inside a <script>, so this one has
      // to name the built path.
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
    minimal_footprint: {
      note: "You said you want to add as little as possible. That rules out CurrentScope, which brings tables, a mounted UI, an audit ledger and a schema guard, and Oso Cloud, which is a paid service your app calls over the network.",
      removes: ["current_scope", "oso"]
    },
    beta: {
      note: "You said production needs 1.0 or later. That rules out CurrentScope, which is in beta, and also Action Policy, which is mature and widely used but has never cut a 1.0 (0.7.6 today). If your rule is about stability rather than the version string, Action Policy is worth a second look.",
      removes: ["current_scope", "action_policy"]
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
      // Answered, not passed: (i + 1) / total. The old form showed 0% on the
      // first question and stopped at 6 of 7, because the verdict replaces the
      // bar and a reader never saw it complete.
      '<div class="cs-fit-bar"><i style="width:' + Math.round(((state.i + 1) / QUESTIONS.length) * 100) + '%"></i></div>' +
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

    // Did the reader describe a CurrentScope-shaped problem and then rule it
    // out? Every answer that expresses one of its strengths scores only
    // CurrentScope, so after the filter those answers count for nothing and the
    // verdict falls to whoever picked up incidental points. Saying so is more
    // use than silently handing over a library whose stated cost is the very
    // thing the reader just asked for.
    // Compared against the top score, not against whichever key the scan
    // happened to reach first. Taking the first strict maximum would drop the
    // note wherever CurrentScope only ties for top, which is the same
    // declaration-order bias the winners below are written to avoid.
    var topScore = 0;
    Object.keys(state.score).forEach(function (k) {
      if (state.score[k] > topScore) topScore = state.score[k];
    });
    var ruledOutTheBestFit = !!out.current_scope && topScore > 0 &&
      (state.score.current_scope || 0) === topScore;

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
      var why = '<ul class="cs-fit-why">';
      state.vetoes.forEach(function (v) { why += "<li>" + VETOES[v].note + "</li>"; });
      why += "</ul>";
      none.innerHTML = '<div class="cs-fit-step">Based on your answers</div>' +
        "<h3>None of these</h3>" +
        "<p>Taken together, your answers rule out every library on this page:</p>" + why +
        (ruledOutTheBestFit
          ? "<p>Your other answers described what CurrentScope is for, so the disqualifier " +
            "above is the whole of why it is not the answer here.</p>"
          : "") +
        "<p>That combination is a real one, and it is worth knowing before you start rather " +
        "than three months in. The table above is where to weigh the trade you are going to " +
        "have to make.</p>" +
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

    if (ruledOutTheBestFit) {
      html += "<p>Your other answers described what CurrentScope is for, so read the " +
        "recommendation above as the closest thing you can use rather than a match: " +
        "whatever you needed from a role screen, per-record grants or an audit trail, " +
        "you will be building on top of it.</p>";
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
