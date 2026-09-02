require "test_helper"
require "ferrum"
require "tmpdir"
require "fileutils"

# The fit chooser on docs/site/comparison.md is the most consequential logic in
# the docs site: it tells a reader which authorization library to adopt, and it
# is the page whose stated purpose is to help them say no.
#
# It was pinned only by matching source text, which cannot see any of the things
# that have actually been wrong with it: a veto that removed our own gem and
# then recommended a Rails-only one anyway, ties resolved by the order the
# object literal happens to be written in, a library that could never be
# reached, and verdicts that named an upside with no cost.
#
# So this drives the real chooser. The page is Jekyll Markdown with the widget
# inline, so the test assembles the same three parts Jekyll would (the mount
# point, the style and the script) into a plain HTML file and walks every answer
# path in the browser.
class DocsSiteFitChooserTest < ActiveSupport::TestCase
  PAGE = File.expand_path("../../docs/site/comparison.md", __dir__)

  # Every library here answers only for a Rails app, so none of them may be the
  # verdict once the reader says something outside Rails needs the same answer.
  RAILS_ONLY = [ "CurrentScope", "Pundit", "Action Policy", "CanCanCan" ].freeze

  setup do
    source  = File.read(PAGE, encoding: "UTF-8")
    mount   = source[/<div id="fitter".*?<\/div>/m] or flunk "the chooser lost its mount point"
    style   = source[/<style>\n(.*?)<\/style>/m, 1] or flunk "the chooser lost its styles"
    script  = source[/<script>\n(.*?)<\/script>/m, 1] or flunk "the chooser lost its script"

    @dir = Dir.mktmpdir("cs-fit")
    File.write(File.join(@dir, "fit.html"), <<~HTML)
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <style>#{style}</style></head><body>#{mount}
      <script>#{script}</script></body></html>
    HTML

    @browser = Ferrum::Browser.new(
      headless: true, window_size: [ 1280, 900 ], process_timeout: 30,
      # every_path replays all 324 answer paths in one evaluate, which is a few
      # thousand re-renders. Ferrum's per-command CDP timeout defaults to 5s and
      # process_timeout does not cover it, so that call can time out under load
      # and report as a browser error rather than a readable assertion.
      timeout: 60,
      browser_options: { "no-sandbox" => nil }
    )
    @page = @browser.create_page
    @page.go_to("file://#{File.join(@dir, 'fit.html')}")
  end

  teardown do
    @browser&.quit
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # Walks every combination of answers by clicking, and reports what each one
  # was actually told. Done in one browser-side pass: each click re-renders
  # synchronously, so no waiting is involved and the whole space is cheap.
  def every_path
    @page.evaluate(<<~JS)
      (function () {
        var mount = document.querySelector("[data-fitter]");

        // Back to question one first. Without this the shape below is measured
        // from wherever a previous walk left the widget, and every answer index
        // shifts silently: the walk still runs and the assertions still pass,
        // but on the wrong paths.
        var reset = mount.querySelector("[data-restart]");
        if (reset) reset.click();
        if (!mount.querySelector(".cs-fit-opts")) return [];

        var counts = [];
        // Discover the shape by walking once with the first option each time.
        while (mount.querySelector(".cs-fit-opts")) {
          counts.push(mount.querySelectorAll(".cs-fit-opts button").length);
          mount.querySelector(".cs-fit-opts button").click();
        }

        var paths = [[]];
        counts.forEach(function (n) {
          var next = [];
          paths.forEach(function (p) {
            for (var i = 0; i < n; i++) next.push(p.concat(i));
          });
          paths = next;
        });

        function restart() {
          var again = mount.querySelector("[data-restart]");
          if (again) again.click();
        }

        return paths.map(function (path) {
          restart();
          path.forEach(function (choice) {
            var opts = mount.querySelectorAll(".cs-fit-opts button");
            if (opts.length) opts[Math.min(choice, opts.length - 1)].click();
          });
          var verdict = mount.querySelector(".cs-fit-verdict");
          return {
            answers: path,
            heading: verdict ? verdict.querySelector("h3").textContent : null,
            body: verdict ? verdict.textContent : null,
            // The disqualifiers render in their own list; matching the prose
            // would also catch a library's cost line saying "still in beta".
            vetoed: !!(verdict && verdict.querySelector(".cs-fit-why"))
          };
        });
      })()
    JS
  end

  test "every answer path reaches a verdict that names a library and its cost" do
    results = every_path
    assert_operator results.length, :>=, 100, "expected the chooser's full answer space"

    blank = results.reject { |r| r["heading"].to_s.strip.length.positive? }
    assert_empty blank.first(3), "some answers reached no verdict at all"

    costless = results.reject { |r| r["body"].to_s.include?("What you give up") }
    assert_empty costless.map { |r| r["answers"] }.first(3),
                 "a verdict named a library with no cost: naming only the upside is the " \
                 "flattering kind this page exists to avoid"
  end

  test "saying something outside Rails needs the same answer rules out every Rails-only library" do
    # Find the polyglot question by its text, then the affirmative option.
    polyglot = @page.evaluate(<<~JS)
      (function () {
        var mount = document.querySelector("[data-fitter]");
        var again = mount.querySelector("[data-restart]");
        if (again) again.click();
        for (var q = 0; q < 12; q++) {
          var text = (mount.querySelector(".cs-fit-q") || {}).textContent || "";
          var opts = mount.querySelectorAll(".cs-fit-opts button");
          if (!opts.length) break;
          if (/other than a Rails app|outside Rails|another language/i.test(text)) return q;
          opts[0].click();
        }
        return -1;
      })()
    JS
    refute_equal(-1, polyglot, "the chooser no longer asks whether anything outside Rails needs it")

    offenders = every_path.select { |r| r["answers"][polyglot].zero? }
                          .select { |r| RAILS_ONLY.include?(r["heading"].to_s.strip) }

    assert_empty offenders.map { |r| r["answers"] }.first(5),
                 "after that answer the chooser still recommended a Rails-only library"
  end

  test "the chooser never recommends CurrentScope to a reader it has ruled it out for" do
    results = every_path
    # A veto states itself in its own list, so a path that shows one must not
    # also be headlining the library that veto exists to rule out.
    vetoed = results.select { |r| r["vetoed"] }
    refute_empty vetoed, "no answer path was able to rule CurrentScope out"

    assert_empty vetoed.select { |r| r["heading"].to_s.include?("CurrentScope") }
                       .map { |r| r["answers"] }.first(5),
                 "a path that ruled CurrentScope out still recommended it"
  end

  test "every library the chooser can offer is reachable by some answer" do
    headings = every_path.map { |r| r["heading"].to_s }
    offered = @page.evaluate(<<~JS)
      (function () {
        // The names the chooser is willing to print, read from the page itself.
        var m = document.documentElement.innerHTML.match(/name: "([^"]+)"/g) || [];
        return m.map(function (s) { return s.replace(/name: "|"/g, "") });
      })()
    JS
    refute_empty offered, "the chooser has to offer at least one library"

    unreachable = offered.reject { |name| headings.any? { |h| h.include?(name) } }
    assert_empty unreachable,
                 "these libraries are in the chooser's data but no answer can reach them, so " \
                 "their entries are dead code that reads as a live recommendation"
  end

  test "a mis-click can be undone without starting over" do
    steps = @page.evaluate(<<~JS)
      (function () {
        var mount = document.querySelector("[data-fitter]");
        var again = mount.querySelector("[data-restart]");
        if (again) again.click();
        var seen = { firstHasBack: !!mount.querySelector("[data-back]") };
        mount.querySelector(".cs-fit-opts button").click();
        seen.step2 = (mount.querySelector(".cs-fit-step") || {}).textContent;
        seen.secondHasBack = !!mount.querySelector("[data-back]");
        mount.querySelector("[data-back]").click();
        seen.afterBack = (mount.querySelector(".cs-fit-step") || {}).textContent;
        return seen;
      })()
    JS

    refute steps["firstHasBack"], "there is nothing to go back to on the first question"
    assert steps["secondHasBack"], "a mis-click on question one has to be undoable"
    assert_equal steps["step2"].to_s.sub("2", "1"), steps["afterBack"],
                 "Back has to return to the previous question"
  end
end
