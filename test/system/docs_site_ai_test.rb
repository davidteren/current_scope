require "test_helper"
require "ferrum"
require "tmpdir"
require "fileutils"
require_relative "support/headless_chrome"
require_relative "../../docs/site/_build/docs_site"

# DocsSiteAiTest string-asserts the alternate/llms-full markup. That cannot
# see a link that is hidden, or a corpus file that 404s when followed. This
# loads the landing page the way a reader does and follows llms-full.txt.
class DocsSiteAiBrowseTest < ActiveSupport::TestCase
  include HeadlessChrome

  LANDING = File.expand_path("../../docs/site/index.html", __dir__)
  ROOT = File.expand_path("../..", __dir__)

  setup do
    @dir = Dir.mktmpdir("cs-docs-ai")
    FileUtils.cp(LANDING, File.join(@dir, "index.html"))
    DocsSite::Builder.new(ROOT).publish!(@dir)

    @browser = open_browser(size: [ 1440, 1000 ])
    @page = @browser.create_page
    @page.network.blocklist = [ %r{\Ahttps?://} ]
    @page.go_to("file://#{File.join(@dir, "index.html")}")
    wait_until(timeout: 15, message: "the landing page never finished parsing") do
      @page.evaluate("document.readyState") != "loading"
    end
  end

  teardown do
    @browser&.quit
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "the landing page advertises its Markdown twin and serves llms-full.txt" do
    href = @page.evaluate(<<~JS)
      (function () {
        var l = document.querySelector('link[rel="alternate"][type="text/markdown"]');
        return l ? l.getAttribute("href") : null;
      })()
    JS
    assert_includes href.to_s, "index.md"

    found = @page.evaluate(<<~JS)
      (function () {
        var a = document.getElementById("llms_full");
        if (!a) return { ok: false, reason: "missing" };
        var r = a.getBoundingClientRect();
        return {
          ok: !a.hidden && r.height > 0 && r.width > 0,
          href: a.getAttribute("href")
        };
      })()
    JS
    assert found["ok"], "llms-full.txt link is not visible (#{found.inspect})"
    assert_equal "llms-full.txt", found["href"]

    @page.evaluate(<<~JS)
      (function () {
        var a = document.getElementById("llms_full");
        a.scrollIntoView();
        a.click();
      })()
    JS

    wait_until(timeout: 15, message: "clicking llms-full.txt never navigated") do
      @page.evaluate("location.href").to_s.include?("llms-full.txt")
    end

    text = @page.evaluate("document.body.innerText").to_s
    assert_includes text, "Prefer llms.txt when you only need the index"
    assert_includes text, "https://davidteren.github.io/current_scope/checking-permissions.md"
    refute_includes text, "](docs/guides/checking-permissions.md"
  end
end
