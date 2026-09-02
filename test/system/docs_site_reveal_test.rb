require "test_helper"
require "ferrum"
require_relative "support/headless_chrome"

# The landing page's scroll reveal has been wrong in three different ways, and
# every one of them looked fine in the source:
#
#   1. An unconditional 2.6s timer revealed everything, so the animation never
#      played for anybody.
#   2. Making that timer conditional meant a client that never scrolls — a
#      crawler, a print, a screenshot, an agent reading the site — could be left
#      looking at empty sections.
#   3. Declaring the transition on the hiding rule alone meant the rule stopped
#      matching the instant the element was revealed, which drops the
#      per-sibling delay: the section arrived as one block instead of in turn.
#
# None of those can be caught by matching strings in the file, which is what the
# unit pins in test/docs_site_test.rb were reduced to doing. This drives the real
# page in a real browser instead, which is also what AGENTS.md asks for.
#
# It does not boot the app: the page is static, so it is loaded over file://.
class DocsSiteRevealTest < ActiveSupport::TestCase
  include HeadlessChrome

  LANDING = File.expand_path("../../docs/site/index.html", __dir__)

  setup do
    @browser = open_browser(size: [ 1440, 1000 ])
    @page = @browser.create_page
    # The reveal is skipped entirely under prefers-reduced-motion, and correctly
    # so. Unpinned, these tests would read the machine's accessibility setting
    # and fail against a page behaving exactly as designed.
    @page.command("Emulation.setEmulatedMedia", media: "screen",
                  features: [ { "name" => "prefers-reduced-motion", "value" => "no-preference" } ])
    @page.go_to("file://#{LANDING}")

    # Not wait_for_idle: the page fires a decorative cross-origin fetch to
    # rubygems.org for the version badge, so on a runner with restricted egress
    # every test would pay the full timeout before starting. Nothing here
    # depends on that request. Wait for the document and the elements instead,
    # and let a real browser error raise where it happens rather than swallowing
    # it into a confusing assertion failure later.
    # Not "complete": that waits for the load event, which is blocked by three
    # remote badge images (shields.io, the CI badge). A runner with restricted
    # egress would fail every test here in setup, which is the same coupling
    # the note above avoids for the rubygems fetch. The reveal script sits at
    # the end of <body>, so "interactive" is already past it.
    wait_until(timeout: 15, message: "the landing page never finished parsing") do
      @page.evaluate("document.readyState") != "loading" &&
        @page.evaluate("document.querySelectorAll('.reveal').length") > 0
    end
  end

  teardown { @browser&.quit }

  # scroll-behavior is smooth on this page, so scrollIntoView animates for
  # 400-500ms before the section is even in view, and the last card then waits
  # out its stagger (up to 4 x 70ms) plus a 600ms fade. A fixed sleep sized to
  # that is a race on a loaded runner; wait for the condition instead.
  # `message` may be a proc, so a failure can report what was actually seen
  # rather than a value captured before the first sample.
  def wait_until(timeout: 12, message: "condition never held")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk message.respond_to?(:call) ? message.call : message
      end

      sleep 0.05
    end
  end

  # The first scroll arms the reveal; the transient arming class is removed in a
  # requestAnimationFrame callback, so waiting a fixed 300ms for it is a race on
  # a loaded runner.
  def arm!
    @page.evaluate("window.scrollTo(0, 200)")
    wait_until(message: "the first scroll has to arm the reveal") do
      @page.evaluate("document.documentElement.classList.contains('js-reveal')")
    end
    wait_until(message: "the arming class is transient; leaving it on disables every transition") do
      !@page.evaluate("document.documentElement.classList.contains('js-reveal-arming')")
    end
  end

  # Defined on the class, not inside a test block: a `def` inside a block still
  # lands on the class, but only once that test has run, so a same-named helper
  # elsewhere would behave differently under Minitest's random ordering.
  def hex(value)
    m = value.to_s.match(/rgba?\((\d+),\s*(\d+),\s*(\d+)/) or return value.to_s.downcase
    format("#%02x%02x%02x", m[1].to_i, m[2].to_i, m[3].to_i)
  end

  def opacities(selector = ".reveal")
    @page.evaluate(<<~JS)
      Array.prototype.map.call(document.querySelectorAll(#{selector.inspect}),
        function (el) { return parseFloat(getComputedStyle(el).opacity) })
    JS
  end

  # A CSS custom property that does not exist, or a selector that loses to a
  # more specific one, is invisible in the source and obvious on screen. This
  # one shipped: `.cta-more a` (0,1,1) lost to `main :is(p,...) a` (0,1,3), so
  # the three secondary links rendered as full accent underlined links and
  # competed with the single primary button they were demoted in favour of.
  test "the secondary calls to action are quieter than the primary one" do
    colours = @page.evaluate(<<~JS)
      (function () {
        var link = document.querySelector(".cta-more a");
        var root = getComputedStyle(document.documentElement);
        return {
          link: link ? getComputedStyle(link).color : null,
          accent: root.getPropertyValue("--accent").trim(),
          accent2: root.getPropertyValue("--accent2").trim(),
          dim: root.getPropertyValue("--dim").trim()
        };
      })()
    JS

    refute_nil colours["link"], "the landing page lost its secondary calls to action"

    actual = hex(colours["link"])
    [ "accent", "accent2" ].each do |name|
      refute_equal hex(colours[name]), actual,
                   "the secondary links render in --#{name}, so they compete with the primary " \
                   "button instead of sitting below it"
    end
    assert_equal hex(colours["dim"]), actual,
                 "the secondary links should carry the palette's quiet tone"

    # Same specificity leak, different victim: a .btn inside a <p> in <main>
    # inherits the prose underline and renders unlike every other button.
    underlined = @page.evaluate(<<~JS)
      Array.prototype.filter.call(document.querySelectorAll("a.btn"), function (b) {
        return getComputedStyle(b).textDecorationLine.indexOf("underline") > -1;
      }).map(function (b) { return b.textContent.trim().slice(0, 40) })
    JS
    assert_empty underlined,
                 "these buttons render underlined, unlike every other button on the page"
  end

  test "a client that never scrolls sees the whole page" do
    values = opacities
    assert_operator values.length, :>=, 10, "expected the page's revealed sections"
    assert_empty values.reject { |o| o > 0.99 },
                 "nothing may be hidden from a reader, crawler or printer that never scrolls"
  end

  test "the first scroll hides what is still below the reader, and reveals it on arrival" do
    arm!

    hidden = opacities.count { |o| o < 0.01 }
    assert_operator hidden, :>, 0, "sections below the reader are handed to the observer"

    @page.evaluate("document.querySelector('#features').scrollIntoView()")
    wait_until(message: "a section the reader has arrived at must become visible") do
      opacities("#features .reveal").all? { |o| o > 0.99 }
    end
  end

  # The observer's root is shrunk 8% at the bottom, and the timer that used to
  # rescue anything it missed is gone, so an element that never intersects would
  # stay invisible for good. No element sits in that band today, which is
  # exactly why it needs pinning: adding a short trailing band or a `reveal` on
  # the footer row would blank it in production and nothing would say so.
  test "nothing is left hidden once the reader reaches the bottom" do
    arm!
    @page.evaluate("window.scrollTo(0, document.body.scrollHeight)")

    wait_until(message: "an element the reader has scrolled past is still hidden") do
      opacities.all? { |o| o > 0.99 }
    end
  end

  # The regression that shipped: the transition and its per-sibling delay were
  # declared only on the hiding rule, `.js-reveal .reveal:not(.in)`, which stops
  # matching the moment the element is revealed.
  #
  # Two things that do NOT catch it, both tried first: reading a hidden
  # element's computed style reports 0.6s in either shape, because the hidden
  # element still matches that rule; and asserting "some opacity is between 0
  # and 1" passes in either shape too, because Chrome still runs a fade.
  #
  # What actually breaks is the choreography. Measured on this page: with the
  # working rule the siblings sit at seven different opacities as they arrive in
  # turn (0.47, 0.21, 0.03, 0, 0, 0, 0). With the transition on the hiding rule
  # the delay is dropped, so every sibling moves as one block and the first has
  # already jumped to 1 (1, 0.47, 0.47, 0.47, 0.47, 0.47, 0.47). Counting the
  # distinct opacities within one sample separates them cleanly.
  test "revealed siblings arrive in turn rather than as one block" do
    arm!

    before = opacities("#features .reveal")
    assert_operator before.length, :>=, 4,
                    "the stagger is only observable across several siblings"
    # Without this the next assertion can fail for the wrong reason: if the hero
    # ever gets shorter, #features is above the fold at arm time, is revealed
    # immediately, and the stagger message would blame CSS that is fine.
    assert_empty before.reject { |o| o < 0.01 },
                 "#features has to start below the reader for its arrival to be observable"

    # Recorded inside the browser, on its own animation frames, and read back
    # once at the end. Two earlier shapes were both races: a browser-side busy
    # loop blocks the main thread so nothing animates at all, and polling from
    # Ruby can be descheduled straight through the ~900ms in which the stagger
    # is visible, failing on a page that is behaving correctly.
    # execute, not evaluate: evaluate wraps a single expression, so a
    # multi-statement script silently does nothing at all.
    @page.execute(<<~JS)
      window.__reveal = [];
      (function record() {
        window.__reveal.push(Array.prototype.map.call(
          document.querySelectorAll("#features .reveal"),
          function (el) { return parseFloat(getComputedStyle(el).opacity) }));
        if (window.__reveal.length < 180) requestAnimationFrame(record);
      })();
      document.querySelector("#features").scrollIntoView();
    JS

    wait_until(message: "the fade has to finish") do
      opacities("#features .reveal").all? { |o| o > 0.99 }
    end

    frames = @page.evaluate("window.__reveal")
    spread = frames.map { |row| row.uniq.length }.max
    assert_operator spread, :>=, 3,
                    "across #{frames.length} animation frames the siblings never held more " \
                    "than #{spread} distinct opacities, so they moved as one block: the " \
                    "transition-delay is on a selector that stops matching at the reveal"
  end
end
