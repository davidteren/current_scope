---
title: "A browser test reads the machine it runs on: theme, motion, the network, the launch budget"
module: test/system/support/headless_chrome.rb
date: 2026-09-05
problem_type: workflow_issue
component: testing_framework
category: workflow-issues
severity: high
applies_when:
  - "Writing a system test that drives a real page in a real browser (cuprite, ferrum, Capybara)"
  - "Testing a page whose CSS or JS reads a media query (`prefers-color-scheme`, `prefers-reduced-motion`, viewport width)"
  - "Loading a page that references any remote asset: a badge, a font, a CDN script, a JSON fetch"
  - "Reading a browser-test failure that happens only on CI, or only on one developer's machine"
  - "Sizing a launch or command timeout for a headless browser"
symptoms:
  - "A theme test passes on the developer's laptop and fails on `ubuntu-latest`, which prefers light"
  - "An animation test passes for one developer and fails for another who has reduce-motion on"
  - "Every test in a file errors after exactly the timeout, on a runner that drops packets rather than refusing them"
  - "`Ferrum::PendingConnectionsError` naming a shields.io or rubygems.org URL"
  - "`Browser did not produce websocket url within 30 seconds` on a cold shared runner"
  - "A test comment says it does not wait on remote requests, and the harness does"
root_cause: missing_workflow_step
resolution_type: test_fix
related_components:
  - testing_framework
  - "test/system/support/headless_chrome.rb"
  - "test/system/docs_site_theme_toggle_test.rb"
  - "test/system/docs_site_reveal_test.rb"
  - "test/system/docs_site_fit_chooser_test.rb"
  - "docs/reviews/2026-09-04-validation-brief-pr197-201.md"
tags:
  - browser-tests
  - environment-dependence
  - prefers-color-scheme
  - prefers-reduced-motion
  - network-egress
  - ferrum
  - emulated-media
  - ci-only-failure
related_issues:
  - "#201 (merged as d006979): the docs-site tests; 9febf63 on its branch, squashed into d006979, pinned the two media preferences"
  - "#202 (merged as a3695c2): the reveal test aborts remote requests at the network layer"
---

# A browser test reads the machine it runs on

## Context

The docs-site browser tests were wrong in the same way four times in three weeks, and
each time the source looked fine.

**Theme.** The theme-toggle tests assert what the page paints on first load. The
page decides that from `prefers-color-scheme`. Nothing pinned it, so the tests read
the developer's OS setting, which is dark. `ubuntu-latest` prefers light. The tests
could only ever have passed on the machine that wrote them.

**Motion.** The landing page's scroll reveal is skipped under
`prefers-reduced-motion`, correctly. The reveal tests read the machine's accessibility
setting and would have failed against a page behaving exactly as designed.

**The network.** The landing page loads three remote badge images and fetches
rubygems.org for the version. The reveal test's comment said it did not wait on them.
It did: `Ferrum::Page#go_to` waits up to the CDP `timeout` (60 s here) for the main
frame to stop loading, and a request that never answers keeps it loading. When that
wait times out, `go_to` raises `PendingConnectionsError` naming the requests still
pending (`pending_connection_errors` defaults to true). A load that completes with a
fetch still in flight returns normally. With the four requests black-holed, `go_to`
hung for the full 60 s. A runner where DNS fails fast is fine; one that drops packets
is not.

**The launch budget.** Chrome needs longer than 30 s to launch on a cold shared runner
while other jobs run, and these tests open a browser per test. Locally 30 s was plenty.

The theme and motion instances were found by a review pass on the #201 branch before
CI ran (9febf63 says the theme failure would have broken CI on push and no local run
could show it). The launch budget was found by CI. The network instance was found by
the validation pass, which the brief had told to assume a third instance after naming
the theme and the launch budget as its two. All four have one shape: a value the page
reads from its environment, left unpinned, so the test encodes the machine it was
written on.

## Guidance

### Rule 1: enumerate what the page reads, then pin every one of them

Before writing the first assertion, list every input the page takes from outside the
document: each `@media` query in its CSS, each `matchMedia` in its JS, the viewport,
the locale and timezone, and every URL that is not `file://` or the app under test.
Each one is a test input. Pin it, or the OS pins it for you.

For media features, the harness speaks CDP directly:

```ruby
@page.command("Emulation.setEmulatedMedia", media: "screen",
              features: [ { "name" => "prefers-reduced-motion", "value" => "no-preference" } ])
```

`docs_site_theme_toggle_test.rb` pins `prefers-color-scheme` to the value each test is
about; `docs_site_reveal_test.rb` pins `prefers-reduced-motion`. Chrome honours the
emulation: the theme test's OS-ignored mutation went red under emulated light.
The validation brief named two instances and told the validator to assume a third;
the list above is the checklist for the next one.

### Rule 2: a page under test makes no request the test is not about

Abort remote requests at the network layer, before `go_to`:

```ruby
@page.network.blocklist = [ %r{\Ahttps?://} ]
@page.go_to("file://#{LANDING}")
```

An aborted request is finished, not pending, so it cannot keep the frame loading past
the timeout, and the page sees a failed image or fetch and carries on.
With the four remote requests black-holed on purpose, `go_to` returned in 0.08 s.

Do not reach for `wait_for_idle` or `readyState == "complete"` to work around this;
both wait on the same remote requests. Before #202 the reveal test waited on
`readyState != "loading"` instead and its comment said it did not wait on the badges;
the wait it could not opt out of was inside `go_to`. A comment describing what a
library does is a claim: read the library. Ferrum 0.17.2: the wait is
`page.rb:356-370` with `page/frames.rb:124-132`, and the raise is `page.rb:108-123`.

The blocklist stays local to the test that loads a real page. The fit-chooser and
theme-toggle tests assemble their own HTML from the widget's script, style and mount
and load nothing remote, so a shared blocklist would be a knob with one caller.

### Rule 3: budget for the runner, not the laptop

`headless_chrome.rb` sizes `process_timeout: 90` and `timeout: 60` for a cold shared
runner, and says why in the comment: 30 s was enough locally and was not on GitHub
Actions (`Browser did not produce websocket url within 30 seconds`; the 30 s version
is only in #201's pre-squash history). The harness already held the one launcher, so
the change was made once. Any timeout tuned on a warm machine is an environment
dependence in disguise.

### Rule 4: prove each pin by emulating the other value

A pin that is never contradicted is a comment. The theme tests were validated by
emulating the opposite scheme and watching the assertion go red; the egress fix was
validated by intercepting every `http*` request and never continuing it, then timing
`go_to`. That is the same rule as everywhere else in this repo: a test is a pin only
when you have watched it fail.

## Why This Matters

A browser test that reads the machine passes for its author every time and fails for
someone else, which is worse than a flaky test: it is a deterministic disagreement
between two machines, and the person who cannot make it pass is not the one who can
fix it. On CI it fails on every run and blocks every PR that touches the file, or,
for the egress case, blocks every PR on the day the runner's network policy changes.

The cost of pinning is one CDP command or one regex per test file. The cost of not
pinning was four rounds of the same bug.

## When to Apply

- Every new system test that loads a page: run the Rule 1 enumeration before the
  first assertion.
- Every CSS or JS change that adds a `@media` query or a `matchMedia`: the tests for
  that page need a new pin, and a test that goes red under the opposite value.
- Every new remote reference in a page under test: extend the blocklist, or make the
  test explicitly about that request.
- Every "passes locally, fails on CI" report on a browser test: check the four
  inputs above before anything else.

## Examples

### The reveal test's setup comment, before and after #202

Before:

> Not wait_for_idle: the page fires a decorative cross-origin fetch to rubygems.org
> for the version badge, so on a runner with restricted egress every test would pay
> the full timeout before starting. Nothing here depends on that request.

After:

> The page loads three remote badge images and fetches rubygems.org for the
> version. None of them matter here, and `go_to` waits for the main frame to stop
> loading, then raises PendingConnectionsError on anything still outstanding, so on
> a runner that drops packets rather than refusing them every test paid the full 60s
> timeout in setup. Abort them at the network layer instead: the page sees each as a
> failed request and carries on.

The first comment described the wait the author had removed, not the one the library
kept. The proof that the second is true is the blocklist plus the black-holed timing
run, not the comment.

## Related

- [Two test processes, one database](two-test-processes-one-database.md): the other
  environment the suite silently shared, the database file.
- [The exit condition nobody can reach](the-exit-condition-nobody-can-reach.md): its
  closing rule, a test is a pin only when you have watched it fail against the
  defect, is what Rule 4 here applies to browser tests.
- [Validation brief for PRs #197 to #201](../../reviews/2026-09-04-validation-brief-pr197-201.md):
  named this class and said to assume a third instance; there was one.
- [Validation findings for PRs #197 to #201](../../reviews/2026-09-04-validation-findings-pr197-201.md):
  finding 5, the egress instance, with the timing evidence.
