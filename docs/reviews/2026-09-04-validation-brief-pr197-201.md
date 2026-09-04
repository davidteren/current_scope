# Validation brief: the five merged pull requests

Outcome: `docs/reviews/2026-09-04-validation-findings-pr197-201.md`. The transient under Known
soft spots has a root cause there (finding 1) and is fixed in PR #202.

Written 2026-09-04, for a fresh agent asked to validate this work. All five are
on `main` now, so this is a review of what landed rather than a merge decision.

## What landed

| PR | What it claims to do |
|---|---|
| [#197](https://github.com/davidteren/current_scope/pull/197) | `current_scope:report` asks with the model the gate used |
| [#198](https://github.com/davidteren/current_scope/pull/198) | Boot refusals name the database they judged |
| [#199](https://github.com/davidteren/current_scope/pull/199) | Every grant write reaches the audit ledger, not only the console's |
| [#200](https://github.com/davidteren/current_scope/pull/200) | A resource type declares which roles may be granted on it |
| [#201](https://github.com/davidteren/current_scope/pull/201) | The fit comparison, and the docs-site work around it |

`main` after all five: 1109 unit runs, 55 system runs, RuboCop clean.

Every PR conflicted with `main` after the one before it landed. Three were
changelog-only. **#200 was four real code conflicts**, including
`scoped_role_assignment.rb`, where #183 and #199 both added methods after
`private`, and resolving it dropped an `end` that RuboCop caught. That
resolution is the highest-risk edit in the set and deserves a direct read:

```
git show c20f27b -- app/models/current_scope/scoped_role_assignment.rb
```

Two process notes if you repeat any of this:

- `gh pr checks <n> --watch` reported a *previous* run as passing while the
  checks on the new head were still queued. Verify against the head SHA
  (`gh api repos/davidteren/current_scope/commits/<sha>/check-runs`), not the PR.
- Every review thread on the five PRs is resolved. Two marked **action-required** turned out
  to be false positives, established by testing rather than reading (see the
  replies on #200). Resolved does not mean every reviewer was right; it means
  each was answered, and the reasoning is on the thread for you to disagree with.

## The job

Not "do the tests pass". They pass. The job is to find the things a green
suite does not see. Concretely:

1. **Does each PR do what its description says**, on the code rather than the
   commit messages? The descriptions were written by the agent that wrote the
   code, so they are a claim, not evidence.
2. **Which assertions cannot fail?** This branch found repeated cases of tests
   that were green lights unable to go red: a regex matching the file's own
   comment, a `data-fitter` pin that passed with the mount point deleted, a
   scroll pin that matched the wrong listener. Assume more remain. The cheapest
   check is to break the behaviour deliberately and confirm the named test
   fails with the message it advertises.
3. **What did the tests encode about this machine?** The browser tests have
   twice failed only on CI (see Known soft spots). Look for anything else
   environment-dependent: timezone, locale, screen size, network reachability,
   Chrome version.
4. **#199 and #200 touch authorization.** A bug there is a user seeing or doing
   something they should not. Give those the security lens specifically: the
   fail-closed resolver, the separation-of-duties veto, and whether a
   pre-existing grant can outlive the rule that was supposed to stop it.

## Known soft spots, stated plainly

- **The browser tests have twice been environment-dependent in ways only CI
  could show.** First `prefers-color-scheme` (they encoded a dark OS preference;
  `ubuntu-latest` prefers light), then `Ferrum::ProcessTimeoutError` because
  Chrome needs longer than 30s to launch on a cold shared runner, alongside a
  Minitest "missing assertions" on a test whose only check was a wait. All
  fixed; that is two rounds of the same class of problem, so assume a third.
- **The fit page's claims about report mode were wrong until review caught
  them.** It said report mode "decides nothing", when only a missing grant is
  downgraded and the SoD veto still refuses. Worth re-reading every remaining
  claim on that page against the engine, not against the page.

- **An unexplained transient.** One `bin/rails test` run reported 6 errors. It
  was not reproducible in nine subsequent runs and the output was not captured.
  It coincided with heavy concurrent headless-Chrome work. Root cause and fix:
  finding 1 in the findings note, shipped in PR #202.
- **The fit chooser is a ~400-line script inline in a Markdown file.** Its test
  (`test/system/docs_site_fit_chooser_test.rb`) regex-extracts the script,
  style and mount out of `docs/site/comparison.md` and reassembles a page, so
  what it drives is a reconstruction, not what Jekyll ships. A break caused by
  the front matter, the theme layout or kramdown's handling of the raw HTML
  block would not be seen. Moving the script to `docs/site/assets/js/` would
  let both load the same file. Deliberately not done here.
- **The docs-site browser harnesses hand-reproduce just-the-docs v0.12.0's
  include structure** — which wrappers `nav_footer_custom.html` is rendered
  into, and the 800px breakpoint. `HeadlessChrome::THEME_WRITTEN_AGAINST`
  asserts the pin has not moved, so a bump fails loudly, but the reproduction
  itself is only as good as the reading behind it.
- **The comparison page makes factual claims about five other libraries.**
  Release dates and the Oso deprecation were checked against RubyGems and
  GitHub on 2026-09-01 and are dated on the page. Anything about how those
  libraries *work* is a description that deserves a second opinion, and the
  page invites corrections by design.
- **Nothing has been driven through a real Jekyll build.** Jekyll is not
  installed here and the theme is resolved remotely at deploy time, so the
  GitHub Pages build is the first thing that exercises the real page. Worth
  watching after any merge.

## How to run what exists

```
bin/rails test          # unit; 1109 runs on main after #201. NOTE: `rake test` runs nothing and exits 0
bin/rails test:system   # browser; 55 runs, needs Chrome
bundle exec rubocop
```

The docs-site browser tests are `test/system/docs_site_*_test.rb` with shared
setup in `test/system/support/headless_chrome.rb`.

## Rules that still apply

- **Do not merge.** Merging is the human's call, on every one of these.
- Any finding left as "deferred" needs a GitHub issue number, not a "later".
- Replies on PR threads go inline on the thread, prefixed with the agent's
  name, citing the commit SHA that fixed it.
