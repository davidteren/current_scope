require "test_helper"
require "tmpdir"
require_relative "../docs/site/_build/docs_site"

# Pins the AI-friendly docs pipeline (#212, #213): one catalog feeds nav,
# Markdown twins, llms.txt, llms-full.txt, and the sitemap. The Pages build
# cannot load a custom Jekyll plugin, so this is the thing that can drift.
class DocsSiteAiTest < ActiveSupport::TestCase
  ROOT = File.expand_path("..", __dir__)

  setup do
    @builder = DocsSite::Builder.new(ROOT)
  end

  test "the catalog lists every guide and every authored site page" do
    assert_nothing_raised { @builder.assert_catalog_covers_repo! }
  end

  test "gitignore lists every generated site page" do
    gitignore = File.read(File.expand_path("../.gitignore", __dir__), encoding: "UTF-8")
    assert_nothing_raised { @builder.assert_gitignore_covers_generated!(gitignore) }
  end

  test "committed llms.txt matches the generator and points at twins plus llms-full" do
    committed = File.read(File.expand_path("../docs/site/llms.txt", __dir__), encoding: "UTF-8")
    assert_equal @builder.llms_txt, committed

    assert_includes committed, "llms-full.txt"
    @builder.pages.each do |page|
      assert_includes committed, @builder.absolute_url(@builder.markdown_path(page)),
                      "#{page["slug"]} must appear in llms.txt as its Markdown twin"
      refute_includes committed, "raw.githubusercontent.com/davidteren/current_scope/main/docs/guides/",
                      "guides belong on the published site, not as a second GitHub canon"
    end
  end

  test "prepare writes generated pages with nav front matter and rewrites repo links" do
    Dir.mktmpdir("docs-site-prepare") do |dir|
      @builder.prepare!(dir)

      checklist = File.read(File.join(dir, "security-checklist.md"), encoding: "UTF-8")
      assert_includes checklist, 'title: "Security & production checklist"'
      assert_includes checklist, "adopting-in-an-existing-app.md"
      refute_includes checklist, "(guides/"
      assert_includes checklist, "https://github.com/davidteren/current_scope/blob/main/README.md"

      guide = File.read(File.join(dir, "checking-permissions.md"), encoding: "UTF-8")
      assert_includes guide, "parent: \"Concepts\""
      assert_includes guide, "docs/guides/checking-permissions.md"
      assert_includes guide, "limitations.md"
      assert_includes guide, "https://github.com/davidteren/current_scope/blob/main/UPGRADING.md"
      refute_includes guide, "../site/limitations.md"
      refute_includes guide, "../../UPGRADING.md"

      glossary = File.read(File.join(dir, "concepts-and-glossary.md"), encoding: "UTF-8")
      assert_includes glossary, "https://github.com/davidteren/current_scope/blob/main/CONCEPTS.md"
    end
  end

  test "publish writes Markdown twins, llms-full.txt, and sitemap extras" do
    Dir.mktmpdir("docs-site-publish") do |dir|
      File.write(File.join(dir, "sitemap.xml"), <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
          <url>
            <loc>https://davidteren.github.io/current_scope/quickstart.html</loc>
          </url>
        </urlset>
      XML

      @builder.publish!(dir)

      twin = File.read(File.join(dir, "concepts.md"), encoding: "UTF-8")
      refute_match(/\A---/, twin)
      assert_includes twin, "1. SoD veto"
      refute_includes twin, "{% include"

      landing = File.read(File.join(dir, "index.md"), encoding: "UTF-8")
      refute_match(/\A---/, landing)
      assert_includes landing, "bundle add current_scope"

      full = File.read(File.join(dir, "llms-full.txt"), encoding: "UTF-8")
      assert_includes full, "Source: https://davidteren.github.io/current_scope/checking-permissions.md"
      assert_includes full, "## Installation"
      assert_includes full, "# UPGRADING.md"
      assert_includes full, "config.subject_identity"

      sitemap = File.read(File.join(dir, "sitemap.xml"), encoding: "UTF-8")
      @builder.sitemap_urls.each do |url|
        assert_includes sitemap, "<loc>#{url}</loc>", "sitemap must list #{url}"
      end
    end
  end

  test "docs HTML heads advertise the Markdown twin" do
    head = File.read(File.expand_path("../docs/site/_includes/head_custom.html", __dir__), encoding: "UTF-8")
    landing = File.read(File.expand_path("../docs/site/index.html", __dir__), encoding: "UTF-8")

    assert_includes head, 'rel="alternate"'
    assert_includes head, 'type="text/markdown"'
    assert_includes landing, 'rel="alternate"'
    assert_includes landing, 'type="text/markdown"'
    assert_includes landing, "index.md"
    assert_includes landing, "llms-full.txt"
  end

  test "robots.txt keeps crawlers allowed and names major AI bots" do
    robots = File.read(File.expand_path("../docs/site/robots.txt", __dir__), encoding: "UTF-8")
    assert_includes robots, "User-agent: *"
    assert_includes robots, "Allow: /"
    assert_includes robots, "Sitemap: https://davidteren.github.io/current_scope/sitemap.xml"
    %w[GPTBot ClaudeBot Google-Extended PerplexityBot].each do |bot|
      assert_includes robots, "User-agent: #{bot}"
    end
  end

  test "authored site pages point at published guides, not raw GitHub" do
    roots = %w[
      docs/site/quickstart.md
      docs/site/concepts.md
      docs/site/ai-agents.md
      docs/site/separation-of-duties.md
      docs/site/_includes/resolver-order.md
    ]
    roots.each do |rel|
      text = File.read(File.expand_path("../#{rel}", __dir__), encoding: "UTF-8")
      refute_match(%r{github\.com/davidteren/current_scope/blob/main/docs/guides/}, text,
                   "#{rel} should link the published guide, not the GitHub blob")
    end
  end

  test "landing Markdown twin has no front matter so Jekyll cannot replace index.html" do
    landing = File.read(File.expand_path("../docs/site/index.md", __dir__), encoding: "UTF-8")
    refute_match(/\A---/, landing)
  end
end
