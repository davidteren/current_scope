# Docs site — design critique

Method: Josh Puckett's Design Critique (Interface Craft). Evidence: headless
captures of the live site at 1440×1000 and 390×844, light and dark, plus the
`docs/site` source. Captured 2026-09-01 against `main` (v0.5.1).

## Context

Two surfaces sold as one product: a hand-authored marketing page
(`docs/site/index.html`, 11 sections, 11,060px tall) and a just-the-docs
documentation theme behind it. The reader is a senior Rails developer deciding
whether to put an **authorization** library in their app. That word sets the
emotional context: they are looking for reasons to distrust this, and they
should be. A missed permission is a user seeing someone else's data.

## First impressions

The landing page is genuinely good — a real headline with a real claim, a
product mock that shows the actual idea (a grid of ticked cells) rather than a
decorative dashboard, and an install command you can copy. Then you click
"Docs" and land in a different product: different typeface, different palette,
different navigation, forced dark, no way back to the page you came from except
the browser's back button. The seam between marketing and documentation is the
single loudest thing about this site, and it lands at the exact moment the
evaluator is deciding whether the project is serious.

## Visual design

**Two type systems, one product** — the landing page sets headlines in a heavy
grotesque with tight tracking (`-0.03em`) and body copy at ~1.05rem; the docs
use the just-the-docs stack at the theme's defaults. Nothing carries over: not
the display face, not the accent blue, not the surface treatment. The reader
reads the same product name in two visual languages within one click. The fix
is not to restyle the whole theme — it is to carry three tokens across: the
accent, the type scale's top end, and the surface/border pair.

**The theme choice does not survive the click** — the landing page respects
`prefers-color-scheme` and stores an explicit choice in
`localStorage['cs-theme']`; the docs are pinned `color_scheme: dark` in
`_config.yml` with no toggle. A visitor who is on a light OS, or who presses the
sun icon in the header, gets a light marketing page and a dark documentation
site. That is not a preference being ignored; it is the interface forgetting
something the user just told it.

**"stars 0" is on the page, at the top** — the badge row under the install
command renders `stars 0` beside `gem v0.5.1` and `CI passing`. Two of those
three build confidence. The third publishes the project's weakest number in the
hero. Social proof you do not have yet should not be given a slot.

**Seven nav items, two kinds, no distinction** — Features, Install, Docs,
Comparison, GitHub, Showcase, Status. Four are in-page anchors, three leave the
page (one leaves the site entirely). They are styled identically, so the reader
cannot tell which clicks will lose their place. GitHub also appears twice in the
header: once as a word, once as the icon button beside the version pill.

## Interface design

**The comparison is buried in the middle of an 11,000px page** — "Data you edit,
or code you deploy?" sits at y=5193, after five other sections. For a library
whose main competitor is a gem the reader already has installed, that is the
section they came for. It also stops at four libraries (Pundit, CanCanCan,
Action Policy) and does not name Banken or Oso, so a reader evaluating against
either finds nothing.

**No route from the docs back into evaluation** — the docs sidebar lists
Quickstart, Concepts, Separation of duties, Security, Configuration, Upgrading,
For AI agents, Limitations. A reader who arrives on Quickstart from a search
engine has no path to "should I use this at all?" — the comparison exists only
on the marketing page they never saw.

**The quickstart is six commands and none of them can be copied** — the landing
page's single install line has a copy button; the documentation's `bundle`,
`bin/rails generate`, migration and initializer blocks do not
(`enable_copy_code_button` is not set). The page a developer actually works from
is the one without the affordance. This is the cheapest DX win on the site: one
line of config.

**We are missing the chance to show the report before asking for trust** — the
whole adoption story is "run report mode and read the output", and the report's
output is the most persuasive artifact this project has. It appears nowhere on
the site. A reader has to install the gem to see the thing that would convince
them to install the gem.

## Consistency and conventions

**Mobile stacks four equal buttons in a 2×2 block** — Quickstart, Star on
GitHub, View Showcase, Docs all render at the same weight at 390px. Four
same-weight actions is no recommendation at all. Every comparable developer-tool
site (Hotwire, ViewComponent, Sidekiq, Oso) ships one primary and demotes the
rest to text links.

**The beta pill breaks badly at 390px** — "Beta · report-mode pilots welcome ·"
wraps with the trailing separator stranded at the end of line two and the link
alone on line three.

**A capture artifact worth naming** — every below-fold section is
`opacity: 0` until an IntersectionObserver adds `.in`, with a 2.6s
`setTimeout` safety net. It degrades correctly for no-JS and reduced-motion. But
it means any tool that screenshots the page — a crawler, a preview card
generator, an AI agent reading the site — sees blank sections. For a project
that ships a `llms.txt` and a page for AI agents, that is worth knowing.

## User context

The reader is skeptical by role. They are not looking for delight; they are
looking for reasons to believe the author has thought about the failure modes.
The site already does the hardest part of that well — the "Who it is not for"
card and the Limitations page are more honest than most commercial products
manage — and then undercuts it by feeling like two projects stitched together.
Uncommon care here is not more animation. It is: the theme you picked follows
you, the commands you need to run can be copied, and the page that helps you
choose a different library is easy to find.

## Top opportunities

1. **Carry the theme across the seam.** Have the docs read
   `localStorage['cs-theme']` and switch just-the-docs to match, with the same
   toggle in the docs header. The evaluator's choice should survive one click.
2. **Turn on copy buttons in the docs** and give every command block one. One
   line of `_config.yml`.
3. **Promote the comparison to a page of its own**, linked from the header, from
   the landing section, and from the docs sidebar — and cover Banken and Oso, so
   a reader evaluating against them is not left guessing.
4. **Give the landing page one primary action.** Quickstart stays a button; the
   rest become text links. Drop the `stars 0` badge until it helps.
5. **Show the report output on the site.** One realistic `current_scope:report`
   block, on the page that asks for the adoption decision.
