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
      # Matches test/application_system_test_case.rb. Ferrum's own default is
      # 10s, and this suite already found that too short for a cold runner.
      process_timeout: 30,
      browser_options: { "no-sandbox" => nil }
    )
    @page = @browser.create_page
    @page.go_to("file://#{LANDING}")

    # Not wait_for_idle: the page fires a decorative cross-origin fetch to
    # rubygems.org for the version badge, so on a runner with restricted egress
    # every test would pay the full timeout before starting. Nothing here
    # depends on that request. Wait for the document and the elements instead,
    # and let a real browser error raise where it happens rather than swallowing
    # it into a confusing assertion failure later.
    wait_until(timeout: 10, message: "the landing page never finished parsing") do
      @page.evaluate("document.readyState") == "complete" &&
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
  def wait_until(timeout: 6, message: "condition never held")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk message.respond_to?(:call) ? message.call : message
      end

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

    assert_operator opacities("#features .reveal").length, :>=, 4,
                    "the stagger is only observable across several siblings"

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
