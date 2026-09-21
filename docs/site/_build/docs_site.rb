# frozen_string_literal: true

require "fileutils"
require "pathname"
require "yaml"

# Build helpers for https://davidteren.github.io/current_scope/
#
# GitHub Pages runs the github-pages gem, which will not load a custom
# Jekyll plugin. Generation therefore happens around the Jekyll build:
#
#   bin/docs-site prepare   # Jekyll inputs (generated pages, llms.txt)
#   jekyll build
#   bin/docs-site publish _site  # .md twins, llms-full.txt, sitemap extras
#   bin/docs-site check     # catalog coverage, gitignore, committed llms.txt
#
# One catalog (docs/site/_data/doc_tree.yml) feeds human nav, sitemap,
# llms.txt, and llms-full.txt so those lists cannot drift.
module DocsSite
  FRONT_MATTER = /\A---\n.*?\n---\n*/m
  INCLUDE_TAG = /\{\%\s*include\s+([A-Za-z0-9_\/.\-]+)\s*\%\}/
  INLINE_LINK = /\[([^\]]+)\]\(([^)]+)\)/
  REF_LINK = /^([ \t]*\[[^\]]+\]:\s*)<?([^>\s]+)>?/

  class Error < StandardError; end

  class Builder
    attr_reader :root, :tree

    def initialize(root)
      @root = Pathname.new(root)
      @tree = YAML.safe_load(File.read(@root.join("docs/site/_data/doc_tree.yml")), aliases: true)
    end

    def pages
      tree.fetch("pages")
    end

    def extras
      tree.fetch("extras")
    end

    def site_origin
      tree.fetch("site_origin")
    end

    def baseurl
      tree.fetch("baseurl")
    end

    def site_url
      "#{site_origin}#{baseurl}"
    end

    def github_blob
      tree.fetch("github_blob")
    end

    def github_raw
      tree.fetch("github_raw")
    end

    def generated_pages
      pages.select { |page| page["generate"] }
    end

    def generated_slugs
      generated_pages.map { |page| page.fetch("slug") }
    end

    def absolute_url(path)
      path = "/" if path.nil? || path.empty?
      path = "/#{path}" unless path.start_with?("/")
      "#{site_url}#{path == "/" ? "/" : path}"
    end

    def html_path(page)
      page["html"] || "/#{page.fetch("slug")}.html"
    end

    def markdown_path(page)
      page["markdown"] || "/#{page.fetch("slug")}.md"
    end

    def prepare!(site_dir)
      site_dir = Pathname.new(site_dir)
      FileUtils.mkdir_p(site_dir)
      generated_pages.each { |page| write_generated_page(site_dir, page) }
      File.write(site_dir.join("llms.txt"), llms_txt)
    end

    def publish!(built_dir)
      built_dir = Pathname.new(built_dir)
      raise Error, "publish needs a built site at #{built_dir}" unless built_dir.directory?

      pages.each do |page|
        dest = built_dir.join(markdown_path(page).delete_prefix("/"))
        FileUtils.mkdir_p(dest.dirname)
        File.write(dest, markdown_twin(page))
      end
      File.write(built_dir.join("llms.txt"), llms_txt)
      File.write(built_dir.join("llms-full.txt"), llms_full_txt)
      write_sitemap(built_dir)
    end

    def llms_txt
      lines = [ tree.fetch("llms_preamble").rstrip, "", "## Docs", "" ]
      pages.each do |page|
        url = absolute_url(markdown_path(page))
        lines << "- [#{page.fetch("title")}](#{url}): #{page.fetch("description")}"
      end
      lines << ""
      lines << "## Full corpus"
      lines << ""
      lines << "- [llms-full.txt](#{absolute_url("/llms-full.txt")}): every published page above, plus README and UPGRADING highlights, in one file"
      lines << ""
      lines << "## Also on GitHub"
      lines << ""
      tree.fetch("also_on_github").each do |item|
        url = item["url"] || "#{github_raw}/#{item.fetch("path")}"
        lines << "- [#{item.fetch("title")}](#{url}): #{item.fetch("description")}"
      end
      lines << ""
      lines.join("\n")
    end

    def llms_full_txt
      chunks = []
      chunks << tree.fetch("llms_preamble").rstrip
      chunks << ""
      chunks << "This file concatenates the published Markdown twins, then README and UPGRADING highlights. Prefer llms.txt when you only need the index."
      pages.each do |page|
        chunks << ""
        chunks << "---"
        chunks << ""
        chunks << "# #{page.fetch("title")}"
        chunks << ""
        chunks << "Source: #{absolute_url(markdown_path(page))}"
        chunks << ""
        chunks << markdown_twin(page).rstrip
      end
      extras.each do |extra|
        chunks << ""
        chunks << "---"
        chunks << ""
        chunks << "# #{extra.fetch("title")}"
        chunks << ""
        chunks << "Source: #{github_blob}/#{extra.fetch("source")}"
        chunks << ""
        chunks << extra_body(extra).rstrip
      end
      chunks << ""
      chunks.join("\n")
    end

    def markdown_twin(page)
      expand_includes(strip_front_matter(page_body(page)))
    end

    def sitemap_urls
      urls = []
      pages.each do |page|
        urls << absolute_url(html_path(page))
        urls << absolute_url(markdown_path(page))
      end
      urls << absolute_url("/llms.txt")
      urls << absolute_url("/llms-full.txt")
      urls.uniq
    end

    def catalog_sources
      (pages + extras).map { |item| item["source"] }.compact
    end

    def assert_catalog_covers_repo!
      missing_guides = Dir[root.join("docs/guides/*.md").to_s].map { |path|
        Pathname.new(path).relative_path_from(root).to_s
      } - pages.map { |page| page["source"] }
      unless missing_guides.empty?
        raise Error, "doc_tree.yml is missing guides: #{missing_guides.join(", ")}"
      end

      authored = Dir[root.join("docs/site/*.md").to_s].map { |path|
        Pathname.new(path).relative_path_from(root).to_s
      }.reject { |rel|
        slug = File.basename(rel, ".md")
        generated_slugs.include?(slug)
      }
      missing_site = authored - pages.map { |page| page["source"] }
      unless missing_site.empty?
        raise Error, "doc_tree.yml is missing site pages: #{missing_site.join(", ")}"
      end
    end

    def assert_gitignore_covers_generated!(gitignore)
      generated_slugs.each do |slug|
        line = "docs/site/#{slug}.md"
        unless gitignore.lines.map(&:strip).include?(line)
          raise Error, ".gitignore must list generated page #{line}"
        end
      end
    end

    # README/UPGRADING live at the repo root. Concatenated under Pages, a
    # leftover `docs/guides/…` or `CHANGELOG.md` would resolve against
    # github.io and 404. Catalogued sources become published Markdown twins;
    # images use github_raw; everything else uses github_blob.
    def rewrite_extra_links(text, source)
      rewrite_links(text) { |href| rewrite_extra_href(href, source) }
    end

    private

    def page_body(page)
      if page["generate"]
        generated_markdown(page)
      else
        File.read(root.join(page.fetch("source")), encoding: "UTF-8")
      end
    end

    def generated_markdown(page)
      source = File.read(root.join(page.fetch("source")), encoding: "UTF-8")
      body = case page["generate_kind"]
      when "security_checklist"
        rewrite_security_checklist(source, page.fetch("source"))
      else
        rewrite_repo_links(source, page.fetch("source"))
      end
      "#{front_matter_for(page)}#{generated_banner(page)}#{body}"
    end

    def write_generated_page(site_dir, page)
      File.write(site_dir.join("#{page.fetch("slug")}.md"), generated_markdown(page))
    end

    def front_matter_for(page)
      fields = { "title" => page.fetch("title") }
      fields["parent"] = page["parent"] if page["parent"]
      fields["nav_order"] = page["nav_order"] if page["nav_order"]
      yaml = fields.map { |key, value|
        formatted = value.is_a?(Numeric) ? value : value.to_s.inspect
        "#{key}: #{formatted}"
      }.join("\n")
      "---\n#{yaml}\n---\n\n"
    end

    def generated_banner(page)
      rel = page.fetch("source")
      "> Published from [`#{rel}`](#{github_blob}/#{rel}). Edit that file — this page is generated when the docs site builds.\n\n"
    end

    def strip_front_matter(text)
      text.sub(FRONT_MATTER, "")
    end

    def expand_includes(text)
      includes = root.join("docs/site/_includes")
      text.gsub(INCLUDE_TAG) do
        file = includes.join(Regexp.last_match(1))
        raise Error, "missing include #{Regexp.last_match(1)}" unless file.file?

        File.read(file, encoding: "UTF-8")
      end
    end

    def extra_body(extra)
      source = extra.fetch("source")
      text = File.read(root.join(source), encoding: "UTF-8")
      body = case extra["kind"]
      when "readme_highlights"
        readme_highlights(text)
      when "full"
        text
      else
        raise Error, "unknown extra kind #{extra["kind"].inspect}"
      end
      rewrite_extra_links(body, source)
    end

    def readme_highlights(readme)
      parts = []
      intro = readme[/\A.*?(?=^## Screenshots)/m]
      parts << intro if intro
      %w[Is it the right fit? Installation Documentation].each do |heading|
        section = readme[/^## #{Regexp.escape(heading)}$.*?(?=^## |\z)/m]
        parts << section if section
      end
      raise Error, "README highlights came out empty" if parts.empty?

      parts.join("\n").gsub(/\n{3,}/, "\n\n")
    end

    def rewrite_security_checklist(text, source)
      rewrite_links(text) { |href| rewrite_checklist_href(href, source) }
    end

    def rewrite_repo_links(text, source)
      rewrite_links(text) { |href| rewrite_guide_href(href, source) }
    end

    def rewrite_links(text)
      rewritten = text.gsub(INLINE_LINK) do
        "[#{Regexp.last_match(1)}](#{yield Regexp.last_match(2)})"
      end
      rewritten.gsub(REF_LINK) do
        "#{Regexp.last_match(1)}#{yield Regexp.last_match(2)}"
      end
    end

    def rewrite_checklist_href(href, source)
      path, suffix = split_href(href)
      return href if skip_rewrite?(path)

      if path == "../README.md"
        "#{github_blob}/README.md#{suffix}"
      elsif path.start_with?("guides/")
        slug = File.basename(path)
        raise_unknown_slug!(slug, source, href) unless known_markdown_name?(slug)
        "#{slug}#{suffix}"
      elsif known_markdown_name?(File.basename(path))
        "#{File.basename(path)}#{suffix}"
      else
        raise Error, "unrewritable relative link in #{source}: #{href}"
      end
    end

    def rewrite_guide_href(href, source)
      path, suffix = split_href(href)
      return href if skip_rewrite?(path)

      basename = File.basename(path)
      if path.start_with?("../site/") || path == "../SECURITY-CHECKLIST.md"
        slug = (path == "../SECURITY-CHECKLIST.md") ? "security-checklist.md" : basename
        raise_unknown_slug!(slug, source, href) unless known_markdown_name?(slug)
        "#{slug}#{suffix}"
      elsif path.start_with?("../../")
        "#{github_blob}/#{path.delete_prefix("../../")}#{suffix}"
      elsif !path.include?("/") && known_markdown_name?(basename)
        "#{basename}#{suffix}"
      else
        raise Error, "unrewritable relative link in #{source}: #{href}"
      end
    end

    def rewrite_extra_href(href, source)
      path, suffix = split_href(href)
      return href if skip_rewrite?(path) || path.start_with?("/")

      repo_path = extra_repo_path(path, source)
      return href unless repo_path

      page = pages.find { |item| item["source"] == repo_path }
      if page
        "#{absolute_url(markdown_path(page))}#{suffix}"
      elsif extra_image?(repo_path)
        "#{github_raw}/#{repo_path}#{suffix}"
      else
        "#{github_blob}/#{repo_path}#{suffix}"
      end
    end

    def extra_repo_path(path, source)
      resolved = (Pathname.new(File.dirname(source)) + path).cleanpath
      return if resolved.absolute? || resolved.to_s.start_with?("..")

      resolved.to_s
    end

    def extra_image?(path)
      path.match?(/\.(?:png|jpe?g|gif|svg|webp|ico)\z/i)
    end

    def split_href(href)
      path, anchor = href.split("#", 2)
      [ path, anchor ? "##{anchor}" : "" ]
    end

    def skip_rewrite?(path)
      path.nil? || path.empty? || path.start_with?("http://", "https://", "mailto:")
    end

    def known_markdown_name?(name)
      pages.any? { |page| File.basename(markdown_path(page)) == name }
    end

    def raise_unknown_slug!(slug, source, href)
      raise Error, "link #{href} in #{source} points at #{slug}, which is not a published page"
    end

    def write_sitemap(built_dir)
      entries = sitemap_urls.map { |url|
        "  <url>\n    <loc>#{escape_xml(url)}</loc>\n  </url>"
      }.join("\n")
      xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        #{entries}
        </urlset>
      XML
      existing = built_dir.join("sitemap.xml")
      if existing.file?
        current = File.read(existing, encoding: "UTF-8")
        missing = sitemap_urls.reject { |url| current.include?("<loc>#{url}</loc>") }
        unless missing.empty?
          extras = missing.map { |url|
            "  <url>\n    <loc>#{escape_xml(url)}</loc>\n  </url>"
          }.join("\n")
          unless current.sub!("</urlset>", "#{extras}\n</urlset>")
            raise Error, "could not patch #{existing} — no closing urlset"
          end
          File.write(existing, current)
        end
      else
        File.write(existing, xml)
      end
    end

    def escape_xml(text)
      text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end
  end
end
