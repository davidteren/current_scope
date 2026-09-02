require "test_helper"

# The marketing landing page is static HTML (Jekyll passthrough). These pins
# catch a missing section, a reintroduced overclaim, or a lost interactive id
# without standing up a browser harness for GitHub Pages. The class covers the
# other published site pages too, so a page can be pinned beside the one it
# mirrors.
class DocsSiteTest < ActiveSupport::TestCase
  LANDING = File.expand_path("../docs/site/index.html", __dir__)
  QUICKSTART = File.expand_path("../docs/site/quickstart.md", __dir__)
  UPGRADING_PAGE = File.expand_path("../docs/site/upgrading.md", __dir__)

  setup do
    @html = File.read(LANDING, encoding: "UTF-8")
    @doc = Nokogiri::HTML5(@html)
  end

  test "landing page keeps the conversion-page sections and controls" do
    %w[features screens comparison audience quickstart showcase status].each do |id|
      assert @doc.at_css("##{id}"), "expected section ##{id} on the landing page"
    end

    assert @doc.at_css("#copybtn"), "expected the install copy button"
    assert @doc.at_css("#navtoggle"), "expected the mobile nav toggle"
    assert @doc.at_css("#theme"), "expected the theme toggle"
    assert @doc.at_css("#pgrid"), "expected the permission-grid mock"
  end

  test "permission-grid mock is in the HTML with a single tab stop" do
    cells = @doc.css("#pgrid .cell:not(.void)")
    assert_operator cells.length, :>=, 10, "expected static grid cells, not an empty tbody"
    stops = cells.select { |c| c["tabindex"] == "0" }
    assert_equal 1, stops.length, "keyboard users should hit one grid cell, then arrow"
  end

  # The seam between the marketing page and the docs is held together by three
  # string literals in three files. Nothing else notices if one of them moves.
  test "the marketing page and the docs agree on the theme storage key" do
    include_path = File.expand_path("../docs/site/_includes/head_custom.html", __dir__)
    docs_head = File.read(include_path, encoding: "UTF-8")

    # Quote-agnostic on purpose: this pins the key the two files share, not the
    # quote style either one happens to be written in.
    assert_match(/localStorage\.getItem\(["']cs-theme["']\)/, docs_head,
                 "the docs read the key the landing page writes")
    assert_match(/localStorage\.setItem\(["']cs-theme["']/, @html,
                 "the landing page writes the key the docs read")
    assert_match(/just-the-docs-" \+ next \+ "\.css/, docs_head,
                 "just-the-docs switches theme by swapping the stylesheet href, not a class")

    # just-the-docs renders nav_footer_custom.html twice, desktop and mobile.
    # querySelector wires only the first, which is the one a phone cannot see.
    assert_match(/querySelectorAll\("\[data-cs-docs-theme-toggle\]"\)/, docs_head,
                 "both copies of the toggle have to be wired, not just the desktop one")

    # The engine's admin UI already owns data-cs-theme-toggle and [data-cs-theme]
    # with a different contract (cookie-backed, sets aria-pressed). One selector
    # must not mean two things.
    footer = File.read(File.expand_path("../docs/site/_includes/nav_footer_custom.html", __dir__),
                       encoding: "UTF-8")
    button = footer[/<button[^>]*>/] or flunk "the docs sidebar lost its theme toggle"
    refute_match(/\bdata-cs-theme-toggle\b/, button,
                 "the docs toggle must not reuse the engine's admin-UI hook")
    refute_match(/\bcs-theme-toggle\b/, button,
                 "the docs toggle must not reuse the engine's admin-UI class")
    refute_match(/setAttribute\("data-cs-theme"/, docs_head,
                 "[data-cs-theme] is the engine's styling hook; the docs theme by stylesheet")
  end

  test "the fit page keeps its chooser and its no-JavaScript fallback" do
    page = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")

    # Anchored on the element, not the token: `data-fitter` also appears in a
    # CSS selector and in the querySelector call, so deleting the mount point
    # (which deletes the noscript nested in it) would not fail a bare match.
    assert_match(%r{<div id="fitter" data-fitter[^>]*>\s*<noscript>}, page,
                 "the chooser's mount point carries the no-JavaScript fallback")
    # Each question is announced by taking focus, not by a live region. Pin the
    # focus target and its marker, or the mechanism can be removed silently.
    assert_match(/data-focus/, page, "the new question has to be the focus target")
    assert_match(/\.focus\(\)/, page, "each question has to be announced on focus")
    assert_match(/^\| If this is true of you/, page,
                 "the plain-table version is the fallback the noscript promises")
    # A mis-click must not cost the reader a page reload.
    assert_match(/data-back/, page, "the chooser needs a way back from a mis-click")
    assert_match(/\bpop\(\)/, page, "Back has to restore the previous answer")
    # Pin the table's header row, not a bare name: every one of these also
    # appears in prose and in the chooser's own constants, so a loose match
    # passes with the comparison column gone.
    header = page[/^\| \| CurrentScope \|.*$/] or flunk "the comparison table lost its header row"
    %w[Pundit Action\ Policy CanCanCan Banken Oso].each do |lib|
      assert_includes header, lib, "#{lib} needs a column in the comparison table"
    end
  end

  # There are now two comparison tables: the short one on the landing page and
  # the full one on the fit page. Nothing stops a corrected claim on one from
  # contradicting the other, so pin the seam: the landing table may only name
  # libraries the full page covers, and it has to send the reader there.
  test "the landing page's short comparison defers to the full one" do
    page = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")
    covered = page[/^\| \| CurrentScope \|.*$/].to_s.split("|").map(&:strip).reject(&:empty?)

    section = @html[/<section id="comparison">.*?<\/section>/m] or
      flunk "the landing page lost its comparison section"

    %w[Pundit Action\ Policy CanCanCan Banken Oso].each do |lib|
      next unless section.include?(lib)

      assert_includes covered, lib,
                      "the landing table names #{lib}, so the full comparison has to cover it"
    end

    assert_match(%r{href="comparison\.html"}, section,
                 "the short table has to hand the reader to the full one")
  end

  # "Do not use CurrentScope when…" is now written on four surfaces: this list,
  # the landing page's short table, the README, and the fit page. The fit page
  # is the one the chooser reads, so it is the source of truth; every
  # disqualifier it can apply has to appear here too, or the reader who only
  # scrolls the landing page is told less than the one who clicks through.
  test "the landing page's 'pick something else' list names every disqualifier" do
    page = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")
    audience = @html[/<section id="audience">.*?<\/section>/m] or
      flunk "the landing page lost its audience section"

    { "attributes" => /amount|attribute|under 10,000/i,
      "polyglot"   => /outside Rails|not only on Rails|another (language|service)/i,
      "beta"       => /beta/i }.each do |veto, phrase|
      assert_match(/veto: "#{veto}"/, page, "#{veto} is still a disqualifier on the fit page")
      assert_match(phrase, audience,
                   "the landing page's 'not for you' list has to name the #{veto} disqualifier")
    end
  end

  # The README's fit section restates the comparison page's trade-off story, so
  # the two can drift apart. Pin what has to stay true of both: the same five
  # libraries, the same question count, and every disqualifier the chooser can
  # apply also named in the README's "reach for something else" table.
  test "the README fit section agrees with the comparison page" do
    readme = File.read(File.expand_path("../README.md", __dir__), encoding: "UTF-8")
    page   = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")

    section = readme[/^## Is it the right fit\?$.*?(?=^## )/m] or
      flunk "the README lost its fit section"

    %w[Pundit Action\ Policy CanCanCan Banken Oso].each do |lib|
      assert_includes section, lib, "the README fit section names #{lib}"
    end

    count = page.scan(/^\s+q: "/).length
    words = %w[zero one two three four five six seven eight nine]
    assert_includes section.gsub(/\s+/, " "), "#{words.fetch(count) { count.to_s }} questions",
                    "the README says how many questions the page asks; it asks #{count}"
    assert_includes page.gsub(/\s+/, " "), "Answer #{words.fetch(count) { count.to_s }} questions",
                    "the page says how many questions it asks; it asks #{count}"

    { "attribute rules" => "no vocabulary for attribute rules",
      "polyglot" => "outside Rails",
      "beta" => "cannot ship beta" }.each do |veto, phrase|
      assert_match(/veto: "#{veto.split.first}/, page, "#{veto} is still a disqualifier on the page")
      assert_includes section, phrase, "the README names the #{veto} disqualifier"
    end
  end

  # The page exists to help a reader say no. Two answers must be able to rule
  # CurrentScope out on their own, and the verdict must never sell a library
  # without naming what it costs.
  test "the chooser can rule CurrentScope out and never recommends without a caveat" do
    page = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")

    %w[attributes polyglot beta].each do |veto|
      assert_match(/veto: "#{veto}"/, page, "#{veto} has to be reachable from an answer")
      assert_match(/#{veto}: \{\s*\n\s*note:/, page, "#{veto} has to explain itself to the reader")
      assert_match(/#{veto}: \{.*?removes: \[[^\]]+\]/m, page,
                   "#{veto} has to remove the libraries that cannot meet it")
    end
    # The polyglot answer must rule out every Rails-only library, or the reader
    # is told "another language needs this" and handed a Rails-only gem.
    polyglot = page[/polyglot: \{.*?removes: \[([^\]]+)\]/m, 1].to_s
    %w[current_scope pundit action_policy cancancan].each do |lib|
      assert_includes polyglot, lib, "the polyglot veto has to rule out #{lib}"
    end
    assert_match(/What you give up/, page,
                 "a verdict that names only the upside is the flattering kind")

    named = page.scan(/^\s+name: "([^"]+)"/).flatten
    refute_empty named, "the chooser has to offer at least one library"
    assert_equal named.length, page.scan(/^\s+givesUp:/).length,
                 "every library the chooser can recommend needs a stated cost: #{named.join(', ')}"
  end

  # The reveal has been wrong in both directions: an unconditional timer meant
  # it never played, and a conditional one could leave a client that does not
  # scroll looking at empty sections.
  test "nothing is hidden until the reader scrolls" do
    assert_match(/js-reveal-arming/, @html, "arming must not fade the page out")
    assert_match(/\@media\s*print\s*\{\s*\.reveal\s*\{[^}]*opacity:\s*1\s*!important/, @html,
                 "a printed page is never scrolled")

    # The hiding rule is `.js-reveal .reveal:not(.in)`, so whatever adds the
    # `js-reveal` class is what can blank the page. Pin that it is only ever
    # added inside `arm`, and that `arm` only ever runs from a scroll event:
    # a bare `arm()` at load would restore the bug and read as harmless.
    adds = @html.scan(/classList\.add\(\s*'js-reveal'/)
    assert_equal 1, adds.length,
                 "only one place may add the class that hides content"
    assert_match(/addEventListener\('scroll',\s*arm\b/, @html,
                 "arming has to hang off the reader's first scroll")
    refute_match(/^\s*arm\(\)/, @html,
                 "calling arm() directly is what blanks the page for a crawler")
  end

  # The transition and its per-sibling delay have to sit on a selector that
  # still matches once the element is revealed. On the hiding rule alone the
  # delay is dropped, so the siblings arrive as one block instead of in turn.
  #
  # This is a source pin and it can only catch the shape, not the behaviour.
  # The behaviour is measured in test/system/docs_site_reveal_test.rb, which
  # watches the siblings actually arrive; that is the test that goes red.
  test "the reveal transition is declared on a selector that survives .in" do
    refute_match(/:not\(\.in\)\s*\{[^}]*transition-delay/, @html,
                 "a delay that only matches while hidden is dropped at the reveal")
  end

  test "landing page does not reintroduce the view/gate overclaim" do
    refute_match(/can(?:not|'t) disagree|never drift apart/i, @html)
  end

  test "copy failure clears and nav close matches the 980px CSS query" do
    assert_includes @html, "Copy failed. Select the command."
    assert_includes @html, "2600"
    assert_includes @html, "max-width:980px"
    assert_includes @html, "scroll-padding-top:72px"
  end

  # Pin the block, not the bare command name: the prose below the block also
  # names db:test:prepare, so a looser assertion passes with the block broken.
  test "upgrading page's command block runs db:test:prepare after db:migrate" do
    block = <<~SH
      bin/rails current_scope:install:migrations
      bin/rails db:migrate
      bin/rails db:test:prepare
    SH
    assert_includes File.read(UPGRADING_PAGE, encoding: "UTF-8"), block,
                    "the site's 0.4 → 0.5 block must run db:test:prepare, like UPGRADING.md"
  end

  test "quickstart banner links the published security checklist" do
    source = File.read(QUICKSTART, encoding: "UTF-8")
    assert_includes source, "https://davidteren.github.io/current_scope/security-checklist.html"
    refute_match(/\]\(security-checklist\.html\)/, source)
  end
end
