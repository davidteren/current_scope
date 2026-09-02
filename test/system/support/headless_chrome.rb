require "ferrum"

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
  def open_browser(size:, timeout: 30)
    Ferrum::Browser.new(
      headless: true,
      window_size: size,
      process_timeout: 30,
      timeout: timeout,
      browser_options: { "no-sandbox" => nil }
    )
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

  # just-the-docs compiles its first stylesheet from color_scheme, and serves it
  # under that name at the site's baseurl.
  def site_color_scheme = site_config.fetch("color_scheme")
  def site_baseurl = site_config.fetch("baseurl", "").to_s

  def starting_stylesheet
    "#{site_baseurl}/assets/css/just-the-docs-#{site_color_scheme}.css"
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
