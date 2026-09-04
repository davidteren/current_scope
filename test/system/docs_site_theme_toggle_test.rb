require "test_helper"
require "ferrum"
require "tmpdir"
require "fileutils"
require "yaml"
require_relative "support/headless_chrome"

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
  include HeadlessChrome

  SITE = File.expand_path("../../docs/site", __dir__)

  # The widths either side of just-the-docs' `md` breakpoint (800px), which is
  # what decides which copy of the footer include a reader can see.
  DESKTOP = [ 1440, 1000 ].freeze
  MOBILE  = [ 390, 844 ].freeze

  setup do
    # Rendered from the site's own settings, not from literals written here: a
    # harness that hardcodes color_scheme cannot fail when it changes, and the
    # assertions below are all phrased in terms of what it is.
    head   = File.read(File.join(SITE, "_includes/head_custom.html"), encoding: "UTF-8")
                 .gsub("{{ site.color_scheme | jsonify }}", site_color_scheme.to_json)
    footer = File.read(File.join(SITE, "_includes/nav_footer_custom.html"), encoding: "UTF-8")
                 .gsub(/\{\{ '\/' \| relative_url \}\}/, "/")

    @dir = Dir.mktmpdir("cs-theme")
    File.write(File.join(@dir, "docs.html"), <<~HTML)
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <link rel="stylesheet" href="#{starting_stylesheet}">
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

  # just-the-docs v0.12.0's own switcher, which the include prefers whenever it
  # is loaded: it rewrites the first stylesheet's href to
  # assets/css/just-the-docs-<scheme>.css.
  JTD_STUB = <<~'JS'.freeze
    window.jtd = { setTheme: function (t) {
      var l = document.querySelector('link[rel="stylesheet"]');
      l.setAttribute("href", l.getAttribute("href").replace(/just-the-docs-[a-z]+\.css/, "just-the-docs-" + t + ".css"));
    } };
  JS

  # `jtd:` picks which branch of the click handler runs. On the real site the
  # theme's script is loaded in <head>, so window.jtd is always defined and its
  # setTheme is the branch that ships; the swap() fallback beside it runs only
  # if that script is ever absent. A harness that defines neither would exercise
  # the fallback and leave the shipped path untested.
  # With nothing stored, head_custom.html follows the operating system, so the
  # starting theme is decided by prefers-color-scheme. Left unpinned, these
  # tests would encode whatever the machine running them happens to prefer and
  # fail on a runner set the other way: ubuntu-latest reports light.
  def with_page(size, jtd: false, prefers: "dark")
    browser = open_browser(size: size)
    page = browser.create_page
    page.command("Emulation.setEmulatedMedia", media: "screen",
                 features: [ { "name" => "prefers-color-scheme", "value" => prefers } ])
    page.go_to("file://#{File.join(@dir, 'docs.html')}")
    # After load, which is fine: the handler reads window.jtd when it is
    # clicked, not when it is attached.
    page.execute(JTD_STUB) if jtd
    # The buttons are unhidden on DOMContentLoaded, so wait for that rather than
    # for a fixed moment: a slow runner would otherwise read them as still
    # hidden and fail against a page that is about to be correct.
    wait_until(message: "the toggle was never wired") do
      toggles(page).any? { |t| !t["hidden"] }
    end
    yield page
  ensure
    browser&.quit
  end

  def press_visible_toggle(page)
    before = stylesheet(page)
    # Asserted, not indexed blindly. In the failure this file exists to catch —
    # the wrong copy of the footer include gets wired — there is nothing visible
    # to press, and `[0].click()` would raise a JavaScript error on top of the
    # real assertion instead of leaving it to speak for itself.
    pressed = page.evaluate(<<~JS)
      (function () {
        var t = Array.prototype.filter.call(
          document.querySelectorAll("[data-cs-docs-theme-toggle]"),
          function (b) { var r = b.getBoundingClientRect(); return !b.hidden && r.height > 0 })[0];
        if (!t) return false;
        t.click();
        return true;
      })()
    JS
    assert pressed, "there is no visible theme toggle to press"
    # Waits on the effect rather than a fixed moment. `settled?` rather than
    # `wait_until` because a press that changes nothing is exactly what some of
    # these tests assert on: the failure should come from the assertion, with
    # its own message, not from a timeout here.
    settled? { stylesheet(page) != before }
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

  # The harness below hand-reproduces this theme version's include structure.
  # A bump has to be a deliberate step that re-checks it, not a silent one.
  test "the docs theme is the version these harnesses were written against" do
    assert_theme_pin_unchanged
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

    # Both branches. Exercising only the fallback would leave the path that
    # actually ships free to break while the suite stayed green, which is
    # failure mode 1 in this file's header: a visible, pressable, dead control.
    { "with just-the-docs loaded" => true, "without it" => false }.each do |how, jtd|
      test "pressing the toggle changes the stylesheet on #{name}, #{how}" do
        with_page(size, jtd: jtd) do |page|
          before = stylesheet(page)
          press_visible_toggle(page)

          refute_equal before, stylesheet(page),
                       "the control is visible and pressable but the page never changed: " \
                       "just-the-docs themes by swapping the stylesheet href, not by a class"
          # With nothing stored the starting theme is the emulated OS
          # preference, whatever the site is compiled as; site.color_scheme
          # only decides the first stylesheet's name and whether the initial
          # swap has anything to do.
          assert_match(/just-the-docs-light\.css/, stylesheet(page),
                       "this page starts on the emulated dark preference, so one press has " \
                       "to land on light")
        end
      end
    end
  end

  { "with just-the-docs loaded" => true, "without it" => false }.each do |how, jtd|
    test "both copies relabel together and the choice is stored, #{how}" do
      with_page(DESKTOP, jtd: jtd) do |page|
        assert_equal [ "Light theme" ], toggles(page).map { |t| t["label"] }.uniq,
                     "the emulated preference is dark, so the button offers the other one"

        press_visible_toggle(page)

        assert_equal [ "Dark theme" ], toggles(page).map { |t| t["label"] }.uniq,
                     "both copies have to relabel, or the reader who resizes sees the wrong one"
        assert_equal "light", page.evaluate('localStorage.getItem("cs-theme")'),
                     "the choice has to survive to the landing page, which reads the same key"
        assert_empty toggles(page).select { |t| t["hidden"] },
                     "a press that worked must not hide the control"
      end
    end
  end

  # The other half of the same promise: with no stored choice, the docs follow
  # the operating system, exactly as the landing page does.
  test "with nothing stored the docs follow the operating system" do
    with_page(DESKTOP, prefers: "light") do |page|
      assert_match(/just-the-docs-light\.css/, stylesheet(page),
                   "a visitor on a light OS should not be shown a dark documentation site")
      assert_equal [ "Dark theme" ], toggles(page).map { |t| t["label"] }.uniq,
                   "the button has to offer the other theme, not the one already applied"
    end

    with_page(DESKTOP, prefers: "dark") do |page|
      refute_match(/just-the-docs-light\.css/, stylesheet(page),
                   "a visitor on a dark OS should not be flipped to light")
    end
  end

  # The whole point of the seam: what the landing page stored has to be applied
  # here before first paint, without the reader touching anything.
  test "a choice made on the landing page is already applied when the docs load" do
    browser = open_browser(size: DESKTOP)
    page = browser.create_page
    # Emulated dark, so that a light result can only have come from the stored
    # choice and not from the machine's own preference.
    page.command("Emulation.setEmulatedMedia", media: "screen",
                 features: [ { "name" => "prefers-color-scheme", "value" => "dark" } ])
    page.go_to("file://#{File.join(@dir, 'docs.html')}")
    page.evaluate('localStorage.setItem("cs-theme", "light")')
    page.go_to("file://#{File.join(@dir, 'docs.html')}")
    wait_until(message: "the toggle was never wired after the second load") do
      toggles(page).any? { |t| !t["hidden"] }
    end

    assert_match(/just-the-docs-light\.css/, stylesheet(page),
                 "a preference the interface forgets one click after it was given is worse " \
                 "than never offering it")
    assert_equal [ "Dark theme" ], toggles(page).map { |t| t["label"] }.uniq,
                 "the button has to offer the other theme, not the one already applied"
  ensure
    browser&.quit
  end
end
