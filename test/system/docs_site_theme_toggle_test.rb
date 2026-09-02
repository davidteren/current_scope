require "test_helper"
require "ferrum"
require "tmpdir"
require "fileutils"

# The theme seam is the headline of this work: a visitor who picks light on the
# landing page and clicks "Docs" should not land in dark. It is also the part
# with the most ways to look right and be wrong, and two of them shipped.
#
#   1. It manipulated `color-scheme-*` classes, which just-the-docs ignores. A
#      visible, pressable, dead control.
#   2. It wired `document.querySelector`, but just-the-docs renders
#      nav_footer_custom.html TWICE — once in components/sidebar.html inside a
#      desktop-only wrapper, once in components/footer.html inside a mobile-only
#      one. So on a phone the wired button was `display:none` and the visible
#      one was never unhidden: zero usable toggles, on the feature this branch
#      exists to add.
#
# Neither is visible in the source, and matching JavaScript spelling cannot see
# either. This assembles the page the way just-the-docs does, including that
# double render, and drives it at both widths.
class DocsSiteThemeToggleTest < ActiveSupport::TestCase
  SITE = File.expand_path("../../docs/site", __dir__)

  # The widths either side of just-the-docs' `md` breakpoint (800px), which is
  # what decides which copy of the footer include a reader can see.
  DESKTOP = [ 1440, 1000 ].freeze
  MOBILE  = [ 390, 844 ].freeze

  setup do
    head   = File.read(File.join(SITE, "_includes/head_custom.html"), encoding: "UTF-8")
                 .gsub("{{ site.color_scheme | jsonify }}", '"dark"')
    footer = File.read(File.join(SITE, "_includes/nav_footer_custom.html"), encoding: "UTF-8")
                 .gsub(/\{\{ '\/' \| relative_url \}\}/, "/")

    @dir = Dir.mktmpdir("cs-theme")
    File.write(File.join(@dir, "docs.html"), <<~HTML)
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="stylesheet" href="/current_scope/assets/css/just-the-docs-default.css">
      <style>
        /* The theme's own responsive utilities: these decide which copy of the
           footer include a reader can actually see. */
        @media (min-width: 800px) { .d-md-none { display: none !important } }
        @media (max-width: 799px) { .d-md-block.d-none { display: none !important } }
      </style>
      #{head}
      </head><body>
      <div class="d-md-block d-none site-footer">#{footer}</div>
      <div class="d-md-none mt-4 fs-2">#{footer}</div>
      </body></html>
    HTML
  end

  teardown { FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir) }

  def with_page(size)
    browser = Ferrum::Browser.new(
      headless: true, window_size: size, process_timeout: 30, timeout: 30,
      browser_options: { "no-sandbox" => nil }
    )
    page = browser.create_page
    page.go_to("file://#{File.join(@dir, 'docs.html')}")
    sleep 0.2
    yield page
  ensure
    browser&.quit
  end

  def toggles(page)
    page.evaluate(<<~JS)
      Array.prototype.map.call(document.querySelectorAll("[data-cs-docs-theme-toggle]"), function (t) {
        var r = t.getBoundingClientRect();
        return { hidden: t.hidden, visible: r.width > 0 && r.height > 0, label: t.textContent.trim() };
      })
    JS
  end

  def stylesheet(page)
    page.evaluate('document.querySelector("link[rel=stylesheet]").getAttribute("href")').to_s
  end

  { "desktop" => DESKTOP, "mobile" => MOBILE }.each do |name, size|
    test "the reader has exactly one usable theme toggle on #{name}" do
      with_page(size) do |page|
        all = toggles(page)
        assert_equal 2, all.length,
                     "just-the-docs renders the footer include twice; the harness should too"

        usable = all.select { |t| !t["hidden"] && t["visible"] }
        assert_equal 1, usable.length,
                     "a #{name} reader sees #{usable.length} working toggles: wiring only the " \
                     "first copy leaves the visible one dead and the wired one off screen"
      end
    end

    test "clicking the toggle actually changes the stylesheet on #{name}" do
      with_page(size) do |page|
        before = stylesheet(page)
        page.evaluate(<<~JS)
          Array.prototype.filter.call(document.querySelectorAll("[data-cs-docs-theme-toggle]"),
            function (t) { var r = t.getBoundingClientRect(); return !t.hidden && r.height > 0 })[0].click()
        JS
        sleep 0.2

        refute_equal before, stylesheet(page),
                     "the control is visible and pressable but the page never changed: " \
                     "just-the-docs themes by swapping the stylesheet href, not by a class"
        assert_match(/just-the-docs-light\.css/, stylesheet(page),
                     "the stored default here is dark, so one press has to land on light")
      end
    end
  end

  test "both copies of the toggle keep the same label, and the choice is stored" do
    with_page(DESKTOP) do |page|
      assert_equal [ "Light theme" ], toggles(page).map { |t| t["label"] }.uniq,
                   "the button names the action it performs, from a dark starting point"

      page.evaluate(<<~JS)
        Array.prototype.filter.call(document.querySelectorAll("[data-cs-docs-theme-toggle]"),
          function (t) { var r = t.getBoundingClientRect(); return !t.hidden && r.height > 0 })[0].click()
      JS
      sleep 0.2

      assert_equal [ "Dark theme" ], toggles(page).map { |t| t["label"] }.uniq,
                   "both copies have to relabel, or the reader who resizes sees the wrong one"
      assert_equal "light", page.evaluate('localStorage.getItem("cs-theme")'),
                   "the choice has to survive to the landing page, which reads the same key"
    end
  end

  # The whole point of the seam: what the landing page stored has to be applied
  # here before first paint, without the reader touching anything.
  test "a choice made on the landing page is already applied when the docs load" do
    browser = Ferrum::Browser.new(
      headless: true, window_size: DESKTOP, process_timeout: 30, timeout: 30,
      browser_options: { "no-sandbox" => nil }
    )
    page = browser.create_page
    page.go_to("file://#{File.join(@dir, 'docs.html')}")
    page.evaluate('localStorage.setItem("cs-theme", "light")')
    page.go_to("file://#{File.join(@dir, 'docs.html')}")
    sleep 0.2

    assert_match(/just-the-docs-light\.css/, stylesheet(page),
                 "a preference the interface forgets one click after it was given is worse " \
                 "than never offering it")
    assert_equal [ "Dark theme" ], toggles(page).map { |t| t["label"] }.uniq,
                 "the button has to offer the other theme, not the one already applied"
  ensure
    browser&.quit
  end
end
