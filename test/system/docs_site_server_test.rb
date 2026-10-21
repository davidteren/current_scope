require "test_helper"
require "tmpdir"
require_relative "support/headless_chrome"

class DocsSiteServerTest < ActiveSupport::TestCase
  include HeadlessChrome

  setup do
    @dir = Dir.mktmpdir("cs-http")
    File.write(File.join(@dir, "index.html"), "<!doctype html><title>Fixture</title><p>Local fixture</p>")
    @server_thread = serve_site(@dir)
  end

  teardown do
    @browser&.quit
    stop_site
    @other_site&.stop_site
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  test "the browser serves fixtures but blocks a different HTTP origin" do
    @browser = open_browser(size: [ 800, 600 ])
    page = site_page(@browser)
    page.go_to(site_url("index.html"))
    assert_equal "Local fixture", page.evaluate("document.body.innerText")

    # A reachable second server makes this fail if filtering is removed.
    # An unreachable public URL would fail even without an allowlist.
    @other_site = Object.new.extend(HeadlessChrome)
    @other_site.serve_site(@dir)
    error = assert_raises(Ferrum::StatusError) do
      page.go_to(@other_site.site_url("index.html"))
    end
    assert_includes error.message, "ERR_BLOCKED_BY_CLIENT"
  end

  test "stopping the server waits for its thread to exit and can be repeated" do
    assert @server_thread.alive?
    stop_site
    refute @server_thread.alive?, "the fixture server must stop before its directory is removed"
    stop_site
    refute @server_thread.alive?
  end
end
