require "ferrum"
require "yaml"

# One place that knows how this repo launches Chrome for the docs-site tests.
#
# There were four copies of this construction across three files, so a change to
# how CI starts a browser — the sandbox flag, a path, a longer budget for a
# slower runner — had to be made in four places, and missing one produced a
# single mysteriously failing file.
module HeadlessChrome
  # process_timeout covers launching the browser; timeout covers each CDP
  # command. They are separate, and Ferrum's default for the second is 5s, which
  # is far too short for the chooser's answer-space walk.
  #
  # Both are sized for a cold, shared CI runner rather than for a warm laptop.
  # 30s was enough locally and was not on GitHub Actions, which failed with
  # "Browser did not produce websocket url within 30 seconds": these tests open
  # a browser per test rather than reusing the one Capybara keeps, so they pay
  # the launch cost repeatedly and hit it while other jobs are running.
  def open_browser(size:, timeout: 60)
    Ferrum::Browser.new(
      headless: true,
      window_size: size,
      process_timeout: 90,
      timeout: timeout,
      browser_options: { "no-sandbox" => nil }
    )
  end

  # Waiting on a condition, never on a fixed sleep. A sleep sized to an
  # animation, a navigation or a class flip is a race on a loaded runner: it
  # passes locally and fails in CI against a page behaving exactly as designed.
  # `message` may be a proc, so a failure can report what was actually seen.
  def wait_until(timeout: 12, message: "condition never held")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      if yield
        # Recorded, because this IS the check: a test whose only verification is
        # a wait would otherwise be reported by Minitest as missing assertions,
        # which is how CI first told me one of these proved nothing on success.
        assert true, message.respond_to?(:call) ? message.call : message
        return
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk message.respond_to?(:call) ? message.call : message
      end

      sleep 0.05
    end
  end

  # Same polling, but reports whether the condition held instead of failing.
  # For cases where not holding is itself what a test asserts on, so the failure
  # comes from the assertion with its own message rather than from a timeout.
  def settled?(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true if yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end

  # The docs site's own settings, read rather than restated: a harness that
  # hardcodes them cannot fail when they change, which is the one thing a test
  # over a config file is for.
  def site_config
    @site_config ||= begin
      path = File.expand_path("../../../docs/site/_config.yml", __dir__)
      YAML.safe_load_file(path, permitted_classes: [], aliases: true) || {}
    end
  end

  def site_color_scheme = site_config.fetch("color_scheme")
  def site_baseurl = site_config.fetch("baseurl", "").to_s

  # Always `-default.css`, whatever color_scheme says. just-the-docs hardcodes
  # this link (v0.12.0 _includes/head.html:17) and compiles the chosen scheme
  # INTO that file; the scheme never appears in the filename. Deriving the name
  # from color_scheme instead would start the harness on a stylesheet the site
  # never serves, and any logic that reads the scheme back out of the href
  # would be tested against "dark" where production gives "default".
  def starting_stylesheet
    "#{site_baseurl}/assets/css/just-the-docs-default.css"
  end

  # The harness reproduces this version's include structure by hand (which
  # wrappers the footer is rendered into, and at what breakpoint). A bump can
  # move those, so it has to be a deliberate step that re-checks them.
  THEME_WRITTEN_AGAINST = "just-the-docs/just-the-docs@v0.12.0".freeze

  def assert_theme_pin_unchanged
    assert_equal THEME_WRITTEN_AGAINST, site_config["remote_theme"],
                 "the docs theme was bumped. These harnesses hand-reproduce the include " \
                 "structure of #{THEME_WRITTEN_AGAINST} — which wrappers nav_footer_custom.html " \
                 "is rendered into, and the md breakpoint. Re-check those against the new " \
                 "version, then update THEME_WRITTEN_AGAINST."
  end
end
