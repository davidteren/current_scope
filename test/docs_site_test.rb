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
    # How the swap works, and that both copies of the toggle are wired, are
    # behaviour: they are driven at both breakpoints in
    # test/system/docs_site_theme_toggle_test.rb, which goes red on each of the
    # two bugs that actually shipped here. Pinning their spelling as well would
    # go red on a rewrite and stay green on a control that does nothing.

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
    refute_match(/setAttribute\(["']data-cs-theme["']/, docs_head,
                 "[data-cs-theme] is the engine's styling hook; the docs theme by stylesheet")
  end

  test "the fit page keeps its chooser and its no-JavaScript fallback" do
    page = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")

    # Anchored on the element, not the token: `data-fitter` also appears in a
    # CSS selector and in the querySelector call, so deleting the mount point
    # (which deletes the noscript nested in it) would not fail a bare match.
    assert_match(%r{<div id="fitter" data-fitter[^>]*>\s*<noscript>}, page,
                 "the chooser's mount point carries the no-JavaScript fallback")
    assert_match(/^\| If this is true of you/, page,
                 "the plain-table version is the fallback the noscript promises")
    # Focus-based announcement and the Back button are behaviour, and both are
    # driven in test/system/docs_site_fit_chooser_test.rb. Pinning their source
    # spelling here would go red on a rename and stay green on a Back button
    # that restored the wrong answer.
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

    # Read from the landing table's own header, not a list written here: a
    # column added there for a library the full page does not cover is exactly
    # the drift this test exists to catch, and a hardcoded list cannot see it.
    landing = Nokogiri::HTML5.fragment(section).css("table.cmp-table thead th")
                             .map(&:text).map(&:strip)
                             .reject { |h| h.empty? || h == "Question" || h == "CurrentScope" }
    refute_empty landing, "the landing comparison table lost its column headers"

    landing.each do |lib|
      assert_includes covered, lib,
                      "the landing table has a #{lib} column, so the full comparison has to " \
                      "cover it: a reader who follows the link must not find it missing"
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
    # Only the "not a fit" card, so a word used approvingly in the "good fit"
    # card beside it cannot satisfy a disqualifier.
    # No fallback that widens to the rest of the section: a card added after
    # this one could then satisfy a claim this list no longer makes, which is
    # the drift the test exists to catch.
    not_for_you = audience[/<div class="card aud no">.*?<\/div>\s*<\/div>/m] or
      flunk "the landing page lost its 'pick something else' card"

    # Derived from the page, not hardcoded: the comment at the top of
    # comparison.md promises this test fails when a disqualifier there has no
    # counterpart here, and a literal list would quietly not do that.
    claims = { "attributes"        => /rules depend on the record's data or the time/i,
               "polyglot"          => /outside Rails needs the same answer/i,
               "code_review"       => /permission change as a code review/i,
               "minimal_footprint" => /smallest possible dependency/i,
               "beta"              => /cannot put beta software into production/i }

    vetoes = page.scan(/veto: "(\w+)"/).flatten.uniq
    refute_empty vetoes, "the chooser has to be able to rule CurrentScope out"
    assert_equal claims.keys.sort, vetoes.sort,
                 "a disqualifier was added to or removed from the chooser. Every one of them " \
                 "has to be stated on the landing page's 'Pick something else' card and in " \
                 "the README, and named here so this test keeps checking that"

    vetoes.each do |veto|
      assert_match claims.fetch(veto), not_for_you,
                   "the landing page's 'not for you' list has to make the #{veto} claim, " \
                   "not merely use the word somewhere nearby"
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

    # Derived from the comparison table, so adding a library there fails here
    # until the README names it too.
    libraries = page[/^\| \| CurrentScope \|.*$/].to_s.split("|").map(&:strip)
                    .reject { |c| c.empty? || c == "CurrentScope" }
    assert_operator libraries.length, :>=, 5, "expected the comparison table's columns"
    libraries.each do |lib|
      assert_includes section, lib, "the README fit section names #{lib}"
    end

    count = page.scan(/^\s+q: "/).length
    words = %w[zero one two three four five six seven eight nine]
    assert_includes section.gsub(/\s+/, " "), "#{words.fetch(count) { count.to_s }} questions",
                    "the README says how many questions the page asks; it asks #{count}"
    assert_includes page.gsub(/\s+/, " "), "Answer #{words.fetch(count) { count.to_s }} questions",
                    "the page says how many questions it asks; it asks #{count}"

    # Derived, like the landing-page half: a hardcoded list here would let a new
    # disqualifier be added to the chooser while the README quietly fell behind,
    # which is what the other half's failure message already promises it cannot.
    phrases = { "attributes"        => "no vocabulary for attribute rules",
                "polyglot"          => "outside Rails",
                "code_review"       => "should be a code review",
                "minimal_footprint" => "smallest possible dependency",
                "beta"              => "cannot ship beta" }
    vetoes = page.scan(/veto: "(\w+)"/).flatten.uniq
    assert_equal phrases.keys.sort, vetoes.sort,
                 "a disqualifier was added to or removed from the chooser; the README's " \
                 "'Reach for something else when' table has to state it, and it has to be " \
                 "named here so this test keeps checking that"
    vetoes.each do |veto|
      assert_includes section, phrases.fetch(veto),
                      "the README has to name the #{veto} disqualifier"
    end
  end

  # The page exists to help a reader say no. Two answers must be able to rule
  # CurrentScope out on their own, and the verdict must never sell a library
  # without naming what it costs.
  test "the chooser can rule CurrentScope out and never recommends without a caveat" do
    page = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")

    # Only that each disqualifier is reachable from an answer and explains
    # itself. Whether the chooser actually honours them — no verdict without a
    # cost, no Rails-only answer after the polyglot one, no library stranded
    # unreachable — is driven for real in
    # test/system/docs_site_fit_chooser_test.rb, so it is not re-pinned here
    # against the source's indentation and key order.
    page.scan(/veto: "(\w+)"/).flatten.uniq.each do |veto|
      assert_match(/#{veto}:\s*\{/, page, "#{veto} has to be a defined disqualifier")
      assert_match(/#{veto}:\s*\{[^}]*note:/m, page, "#{veto} has to explain itself to the reader")
      assert_match(/#{veto}:\s*\{[^}]*removes:\s*\[[^\]]+\]/m, page,
                   "#{veto} has to remove the libraries that cannot meet it")
    end
  end

  # The reveal's behaviour — a client that never scrolls sees the whole page,
  # and revealed siblings arrive in turn — is measured in a real browser by
  # test/system/docs_site_reveal_test.rb. Only the two things a browser cannot
  # show are pinned here: print, which no headless run exercises, and the fact
  # that exactly one place adds the class that can blank the page.
  test "nothing is hidden from a printed page, and one place can hide content" do
    assert_match(/\@media\s*print\s*\{\s*\.reveal\s*\{[^}]*opacity:\s*1\s*!important/, @html,
                 "a printed page is never scrolled")
    adds = @html.scan(/classList\.add\(\s*["']js-reveal["']/)
    assert_equal 1, adds.length,
                 "only one place may add the class that hides content"
    assert_match(/addEventListener\(\s*["']scroll["']\s*,\s*\w+/, @html,
                 "arming has to hang off the reader's first scroll")
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
