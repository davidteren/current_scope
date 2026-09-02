require "test_helper"
require "ferrum"
require "tmpdir"
require "fileutils"
require_relative "support/headless_chrome"

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
#
# What that does and does not cover: it exercises the shipped script, styles and
# markup, so the scoring, the disqualifiers, the ties, Back and the focus
# announcement are all real. It does NOT build the page through Jekyll, so it
# cannot see a break caused by the front matter, the theme layout, or kramdown's
# handling of the raw HTML block. Building the site here would mean installing
# Jekyll and the remote theme that GitHub Pages resolves at deploy time; the
# Pages build itself is the check for that layer.
class DocsSiteFitChooserTest < ActiveSupport::TestCase
  include HeadlessChrome

  PAGE = File.expand_path("../../docs/site/comparison.md", __dir__)

  # Every library here answers only for a Rails app, so none of them may be the
  # verdict once the reader says something outside Rails needs the same answer.
  RAILS_ONLY = [ "CurrentScope", "Pundit", "Action Policy", "CanCanCan" ].freeze

  setup do
    source = File.read(PAGE, encoding: "UTF-8")

    # Chosen by content, not by position: taking the first <script> or <style>
    # would silently assemble a different widget than the site ships if another
    # block were ever added above the chooser, and the real one would go
    # untested while everything still passed.
    scripts = source.scan(/<script\b[^>]*>(.*?)<\/script>/m).flatten
    styles  = source.scan(/<style\b[^>]*>(.*?)<\/style>/m).flatten
    script  = scripts.find { |b| b.include?("QUESTIONS") && b.include?("LIBS") } or
      flunk "no <script> in comparison.md defines the chooser"
    style   = styles.find { |b| b.include?(".cs-fit") } or
      flunk "no <style> in comparison.md styles the chooser"

    mount = source[/<div id="fitter"[^>]*>.*?<\/div>/m] or flunk "the chooser lost its mount point"
    assert_includes mount, "data-fitter", "the mount point lost the hook the script looks for"
    assert_includes mount, "</noscript>",
                    "the mount match stopped early, so the no-JavaScript fallback is outside it"

    @dir = Dir.mktmpdir("cs-fit")
    File.write(File.join(@dir, "fit.html"), <<~HTML)
      <!doctype html><html lang="en"><head><meta charset="utf-8">
      <style>#{style}</style></head><body>#{mount}
      <script>#{script}</script></body></html>
    HTML

    @page_path = File.join(@dir, "fit.html")
  end

  # Opened only when a test actually drives the widget. Three of them read
  # nothing but the class-level walk, which is computed once, so opening a
  # Chrome for those is three browsers per run doing no work.
  def page
    @page ||= begin
      @browser = open_browser(size: [ 1280, 900 ], timeout: 60)
      opened = @browser.create_page
      opened.go_to("file://#{@page_path}")
      opened
    end
  end

  teardown do
    @browser&.quit
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # Walks every combination of answers by clicking, and reports what each one
  # was actually told. Each click re-renders synchronously, so no waiting is
  # involved. Computed once for the whole class rather than per test, because
  # the page is static and the walk is deterministic: every test reads the same
  # answer, and it takes something that opens a page rather than a page, so a
  # test that only reads the cache never launches a browser at all.
  #
  # Replayed in batches rather than one call. The space is the product of the
  # options on each question, so it grows multiplicatively: seven questions is
  # 972 paths and roughly 6,800 widget rebuilds, and one more three-option
  # question would be about 2,900 paths and 23,000 rebuilds. As a single CDP
  # command that eventually exceeds the timeout and surfaces as a browser error
  # rather than a readable assertion. Batching keeps each command small, so
  # adding a question costs proportionally more time and never a cliff.
  BATCH = 150

  def self.walk(open_page)
    @walk ||= begin
      page = open_page.call
      shape = page.evaluate(SHAPE_JS)
      total = shape.reduce(1) { |n, options| n * options }

      (0...total).step(BATCH).flat_map do |from|
        page.evaluate(format(REPLAY_JS, shape: shape.to_json, from: from, to: from + BATCH))
      end
    end
  end

  def every_path
    self.class.walk(-> { page })
  end

  # Discover the widget's shape: how many options each question offers. Walking
  # with the first option each time is enough, and it starts from a restart so
  # the counts cannot be measured from wherever a previous call left the widget
  # — which would shift every answer index silently, leaving the assertions
  # running happily on the wrong paths.
  SHAPE_JS = <<~JS.freeze
    (function () {
      var mount = document.querySelector("[data-fitter]");
      var again = mount.querySelector("[data-restart]");
      if (again) again.click();

      var counts = [];
      while (mount.querySelector(".cs-fit-opts")) {
        counts.push(mount.querySelectorAll(".cs-fit-opts button").length);
        mount.querySelector(".cs-fit-opts button").click();
      }
      return counts;
    })()
  JS

  # Replay one batch of answer paths and report what each was actually told.
  # Each click re-renders synchronously, so no waiting is involved.
  REPLAY_JS = <<~'JS'.freeze
    (function () {
      var mount = document.querySelector("[data-fitter]");
      var shape = %{shape}, from = %{from}, to = %{to};

      var total = shape.reduce(function (n, o) { return n * o }, 1);
      if (to > total) to = total;

      function pathAt(index) {
        var out = [], rest = index;
        for (var i = shape.length - 1; i >= 0; i--) {
          out[i] = rest %% shape[i];
          rest = Math.floor(rest / shape[i]);
        }
        return out;
      }

      var results = [];
      for (var n = from; n < to; n++) {
        var again = mount.querySelector("[data-restart]");
        if (again) again.click();

        var path = pathAt(n);
        path.forEach(function (choice) {
          var opts = mount.querySelectorAll(".cs-fit-opts button");
          if (opts.length) opts[Math.min(choice, opts.length - 1)].click();
        });

        var verdict = mount.querySelector(".cs-fit-verdict");
        results.push({
          answers: path,
          heading: verdict ? verdict.querySelector("h3").textContent : null,
          body: verdict ? verdict.textContent : null,
          // The disqualifiers render in their own list; matching the prose
          // would also catch a library's cost line saying "still in beta".
          vetoed: !!(verdict && verdict.querySelector(".cs-fit-why"))
        });
      }
      return results;
    })()
  JS

  test "every answer path reaches a verdict that names a library and its cost" do
    results = every_path
    assert_operator results.length, :>=, 100, "expected the chooser's full answer space"

    blank = results.reject { |r| r["heading"].to_s.strip.length.positive? }
    assert_empty blank.first(3), "some answers reached no verdict at all"

    # Some answers rule out everything on the page: needing attribute rules,
    # another language and the smallest possible dependency has no answer here,
    # and saying so is the honest verdict. It names no library, so it has no
    # cost to state, but it must still send the reader somewhere.
    none, named = results.partition { |r| r["heading"].to_s.strip == "None of these" }
    refute_empty named, "every answer path ruled out every library"
    none.each do |r|
      assert_match(/table above/i, r["body"].to_s,
                   "a verdict that recommends nothing has to point somewhere: #{r['answers']}")
    end

    costless = named.reject { |r| r["body"].to_s.include?("What you give up") }
    assert_empty costless.map { |r| r["answers"] }.first(3),
                 "a verdict named a library with no cost: naming only the upside is the " \
                 "flattering kind this page exists to avoid"
  end

  test "saying something outside Rails needs the same answer rules out every Rails-only library" do
    # Find the polyglot question by its text, then the affirmative option.
    polyglot = page.evaluate(<<~JS)
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

    # Substring, not equality: tied winners are joined into one heading
    # ("Pundit or Action Policy"), which matches no exact name, so an equality
    # test would pass straight through the regression this exists to catch.
    offenders = every_path.select { |r| r["answers"][polyglot].zero? }
                          .select { |r| RAILS_ONLY.any? { |n| r["heading"].to_s.include?(n) } }

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
    offered = page.evaluate(<<~JS)
      (function () {
        // The names the chooser is willing to print, read from the page itself.
        var m = document.documentElement.innerHTML.match(/name: "([^"]+)"/g) || [];
        return m.map(function (s) { return s.replace(/name: "|"/g, "") });
      })()
    JS
    refute_empty offered, "the chooser has to offer at least one library"

    # Sole winner, not merely present in a heading. Tied winners are joined into
    # one heading, so an `include?` test passes for a library that can only ever
    # appear alongside another and is never actually the answer: which is how
    # Pundit stayed weakly dominated behind a green test.
    never_the_answer = offered.reject { |name| headings.any? { |h| h.strip == name } }
    assert_empty never_the_answer,
                 "these libraries can never be the chooser's answer on their own, so the page " \
                 "can never send anyone to them even where its own table says it should"
  end

  # Every answer that expresses a CurrentScope-shaped need scores only
  # CurrentScope, so once a veto removes it those answers count for nothing and
  # the verdict falls to whoever picked up incidental points. The reader was
  # then handed a library whose stated cost is the very thing they had just
  # asked for ("no admin screen, no ledger" to someone who said they are
  # audited), with nothing acknowledging the mismatch.
  test "a reader who rules out the library that fitted them is told so" do
    note = "described what CurrentScope is for"

    told = every_path.select { |r| r["vetoed"] && r["body"].to_s.include?(note) }
    refute_empty told,
                 "no vetoed path acknowledges that the reader's other answers fitted " \
                 "CurrentScope, so some of them silently recommend the opposite of what " \
                 "was asked for"

    # A reader who asked for all three of the things CurrentScope exists to give
    # — a role screen an administrator edits, per-record grants, and an audit
    # trail — described it as plainly as the questions allow. If a veto then
    # rules it out, they must always be told, whatever the other scores did.
    # Comparing against the top score rather than the first strict maximum is
    # what makes that hold: the earlier shape dropped the note wherever
    # CurrentScope merely tied, on about 5% of the whole answer space.
    asked_for_all_three = every_path.select do |r|
      r["vetoed"] && r["answers"][2].zero? && r["answers"][3].zero? && r["answers"][4].zero?
    end
    refute_empty asked_for_all_three, "no path asks for all three and then rules them out"

    silent = asked_for_all_three.reject { |r| r["body"].to_s.include?(note) }
    assert_empty silent.map { |r| r["answers"] },
                 "these readers asked for a role screen, per-record grants and an audit " \
                 "trail, ruled CurrentScope out, and were handed something else with no " \
                 "word that their answers had described the library they just excluded"
  end

  # There is no aria-live region: each new question is announced by taking
  # focus. A source pin cannot tell whether focus actually lands.
  test "each question takes focus so a screen reader announces it" do
    landed = page.evaluate(<<~JS)
      (function () {
        var mount = document.querySelector("[data-fitter]");
        var again = mount.querySelector("[data-restart]");
        if (again) again.click();
        var seen = [];
        for (var i = 0; i < 8; i++) {
          var opts = mount.querySelectorAll(".cs-fit-opts button");
          if (!opts.length) break;
          opts[0].click();
          var el = document.activeElement;
          // Inside the widget, not a particular class: the question is a
          // <p class="cs-fit-q"> and the verdict's target is a bare <h3>.
          seen.push({
            inside: !!(el && mount.contains(el)),
            tag: el ? el.tagName : null,
            text: el ? (el.textContent || "").trim().slice(0, 30) : ""
          });
        }
        return seen;
      })()
    JS

    refute_empty landed, "the chooser asked nothing"
    stranded = landed.reject { |f| f["inside"] }
    assert_empty stranded,
                 "after an answer the focus has to land inside the chooser, on the new " \
                 "question or the verdict; otherwise nothing is announced at all"
  end

  test "a mis-click can be undone without starting over" do
    steps = page.evaluate(<<~JS)
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
