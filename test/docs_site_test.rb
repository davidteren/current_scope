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

    assert_match(/localStorage\.getItem\("cs-theme"\)/, docs_head,
                 "the docs read the key the landing page writes")
    assert_match(/localStorage\.getItem\('cs-theme'\)/, @html,
                 "the landing page writes the key the docs read")
    assert_match(/just-the-docs-" \+ next \+ "\.css/, docs_head,
                 "just-the-docs switches theme by swapping the stylesheet href, not a class")
  end

  test "the fit page keeps its chooser and its no-JavaScript fallback" do
    page = File.read(File.expand_path("../docs/site/comparison.md", __dir__), encoding: "UTF-8")

    assert_match(/data-fitter/, page, "the chooser needs its mount point")
    assert_match(/<noscript>/, page, "the chooser must degrade to the table below it")
    assert_match(/aria-live/, page, "each question has to be announced")
    assert_match(/^\| If this is true of you/, page,
                 "the plain-table version is the fallback the noscript promises")
    %w[Pundit Action\ Policy CanCanCan Banken Oso].each do |lib|
      assert_match(/#{lib}/, page, "the comparison names #{lib}")
    end
  end

  # The reveal has been wrong in both directions: an unconditional timer meant
  # it never played, and a conditional one could leave a client that does not
  # scroll looking at empty sections.
  test "nothing is hidden until the reader scrolls" do
    assert_match(/js-reveal-arming/, @html, "arming must not fade the page out")
    assert_match(/classList\.add\('js-reveal'/, @html,
                 "the hiding rule is added on first scroll, not at load")
    assert_match(/@media print\{\.reveal\{opacity:1!important/, @html,
                 "a printed page is never scrolled")
    refute_match(/setTimeout\(revealAll/, @html,
                 "the timer-based reveal is what made the animation pointless")
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
