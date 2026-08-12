require "test_helper"

# The marketing landing page is static HTML (Jekyll passthrough). These pins
# catch a missing section, a reintroduced overclaim, or a lost interactive id
# without standing up a browser harness for GitHub Pages.
class DocsSiteTest < ActiveSupport::TestCase
  LANDING = File.expand_path("../docs/site/index.html", __dir__)
  QUICKSTART = File.expand_path("../docs/site/quickstart.md", __dir__)

  setup do
    @html = File.read(LANDING)
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

  test "landing page does not reintroduce the view/gate overclaim" do
    refute_match(/can(?:not|'t) disagree|never drift apart/i, @html)
  end

  test "copy failure clears and nav close matches the 980px CSS query" do
    assert_includes @html, "Copy failed. Select the command."
    assert_includes @html, "2600"
    assert_includes @html, "max-width:980px"
    assert_includes @html, "scroll-padding-top:72px"
  end

  test "quickstart banner links the published security checklist" do
    source = File.read(QUICKSTART)
    assert_includes source, "https://davidteren.github.io/current_scope/security-checklist.html"
    refute_match(/\]\(security-checklist\.html\)/, source)
  end
end
