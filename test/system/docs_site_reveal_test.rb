require "test_helper"
require "ferrum"

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
  LANDING = File.expand_path("../../docs/site/index.html", __dir__)

  setup do
    @browser = Ferrum::Browser.new(
      headless: true,
      window_size: [ 1440, 1000 ],
      browser_options: { "no-sandbox" => nil }
    )
    @page = @browser.create_page
    @page.go_to("file://#{LANDING}")
    @page.network.wait_for_idle(timeout: 5) rescue nil
  end

  teardown { @browser&.quit }

  # scroll-behavior is smooth on this page, so scrollIntoView animates for
  # 400-500ms before the section is even in view, and the last card then waits
  # out its stagger (up to 4 x 70ms) plus a 600ms fade. A fixed sleep sized to
  # that is a race on a loaded runner; wait for the condition instead.
  def wait_until(timeout: 6, message: "condition never held")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      flunk message if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  def opacities(selector = ".reveal")
    @page.evaluate(<<~JS)
      Array.prototype.map.call(document.querySelectorAll(#{selector.inspect}),
        function (el) { return parseFloat(getComputedStyle(el).opacity) })
    JS
  end

  test "a client that never scrolls sees the whole page" do
    values = opacities
    assert_operator values.length, :>=, 10, "expected the page's revealed sections"
    assert_empty values.reject { |o| o > 0.99 },
                 "nothing may be hidden from a reader, crawler or printer that never scrolls"
  end

  test "the first scroll hides what is still below the reader, and reveals it on arrival" do
    @page.evaluate("window.scrollTo(0, 200)")
    sleep 0.3

    assert @page.evaluate("document.documentElement.classList.contains('js-reveal')"),
           "the first scroll arms the reveal"
    refute @page.evaluate("document.documentElement.classList.contains('js-reveal-arming')"),
           "the arming class is transient; leaving it on would disable every transition"

    hidden = opacities.count { |o| o < 0.01 }
    assert_operator hidden, :>, 0, "sections below the reader are handed to the observer"

    @page.evaluate("document.querySelector('#features').scrollIntoView()")
    wait_until(message: "a section the reader has arrived at must become visible") do
      opacities("#features .reveal").all? { |o| o > 0.99 }
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
    @page.evaluate("window.scrollTo(0, 200)")
    sleep 0.3

    # Sampled from here, not in a browser-side loop: a busy-wait blocks the
    # main thread, so nothing animates and the page stops responding.
    @page.evaluate("document.querySelector('#features').scrollIntoView()")
    samples = []
    6.times do
      sleep 0.05
      samples << opacities("#features .reveal")
    end

    refute_empty samples.flatten, "expected a section with revealed elements"
    assert_operator samples.first.length, :>=, 4,
                    "the stagger is only observable across several siblings"

    spread = samples.map { |row| row.uniq.length }.max
    assert_operator spread, :>=, 3,
                    "the siblings never held more than #{spread} distinct opacities, so they " \
                    "moved as one block: the transition-delay is on a selector that stops " \
                    "matching the moment the element is revealed"

    wait_until(message: "the fade has to finish") do
      opacities("#features .reveal").all? { |o| o > 0.99 }
    end
  end
end
