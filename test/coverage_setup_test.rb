require "test_helper"

# Pins the coverage bootstrap's wiring (#114 follow-up).
#
# The bootstrap only works because of WHEN it loads, and that is not something the
# rest of the suite can notice: delete either require and every test still passes,
# the reported figure just silently drops back to ~35%. test/sod_preflight_test.rb
# records the same shape ("724 runs, 0 failures" after a reviewer deleted a wiring
# initializer), so pin the wiring here the way that test pins its own.
class CoverageSetupTest < ActiveSupport::TestCase
  ROOT = File.expand_path("..", __dir__)
  BOOTSTRAP = File.expand_path("coverage_setup.rb", __dir__)

  test "bin/rails requires the bootstrap before it loads the engine" do
    source = File.read(File.join(ROOT, "bin/rails"))

    # Anchored to the start of a line: both strings also appear in the explanatory
    # comment above them, and matching that would compare the wrong positions.
    require_line = source.index(/^require_relative ["']\.\.\/test\/coverage_setup["']/)
    engine_line  = source.index(/^require ["']rails\/engine\/commands["']/)

    assert require_line, "bin/rails must require test/coverage_setup — without it, " \
                         "`bin/rails test` measures only app/ and reports lib/ at 0%"
    assert engine_line, "bin/rails should still require rails/engine/commands"
    assert require_line < engine_line,
           "the coverage bootstrap must be required BEFORE rails/engine/commands; " \
           "Ruby's Coverage cannot instrument an already-loaded file"
  end

  test "bin/rails arms coverage for the test commands and nothing else" do
    # Build the pattern FROM bin/rails rather than restating it here. A second
    # hand-written copy would pass while the real gate narrowed underneath it —
    # the same silent drift this whole bootstrap exists to prevent.
    source = File.read(File.join(ROOT, "bin/rails"))
    literal = source[%r{ARGV\.first&\.match\?\(/(.+?)/\)}, 1]
    assert literal, "bin/rails should gate the bootstrap on an ARGV regex"
    pattern = Regexp.new(literal)

    # `t` is railties' own alias for `test` (rails/commands.rb), so it must arm too.
    %w[test t test:system test:all].each do |cmd|
      assert pattern.match?(cmd), "`bin/rails #{cmd}` must arm the coverage bootstrap"
    end
    # db:test:prepare loads no tests; arming it would write a near-empty result.
    %w[db:test:prepare console server generate].each do |cmd|
      assert_not pattern.match?(cmd), "`bin/rails #{cmd}` must not arm the bootstrap"
    end
  end

  test "test_helper requires the bootstrap before it loads the app" do
    source = File.read(File.join(__dir__, "test_helper.rb"))

    # Line-anchored so a mention inside a comment cannot satisfy it.
    require_line = source.index(/^require_relative ["']coverage_setup["']/)
    app_line = source.index(%r{^require_relative ["']\.\./test/dummy/config/environment["']})

    assert require_line, "test_helper must require the bootstrap too — " \
                         "`ruby -Itest foo_test.rb` never touches bin/rails, " \
                         "and would record no coverage at all"
    assert app_line, "test_helper should still load the dummy app"
    assert require_line < app_line,
           "the bootstrap must be required before the dummy app loads the engine"
  end

  # The two tests above pin the WIRING. This one pins the OUTCOME: which files the
  # run actually measures. Without it, narrowing `cover` to "app/**/*.rb" would
  # reproduce the original bug — lib/ unmeasured — with the whole suite still green,
  # because nothing else looks at the SimpleCov.start block.
  test "the run measures lib/ and excludes only what no test could reach" do
    skip "coverage is disabled" if ENV["COVERAGE"] == "0"

    # Deliberately against SimpleCov's internals: there is no public API that answers
    # "what would this configuration measure" without running a whole suite. The
    # Gemfile sets no version constraint, so read Gemfile.lock for the version in
    # use. The assertion below guards the two method names only. An upgrade that
    # keeps them and changes filter semantics walks straight through it, and the
    # measured-set assertions further down are what would catch that. When it does
    # fail, re-derive this from SimpleCov::Result#apply_cover_filters! rather than
    # deleting the test.
    assert SimpleCov.respond_to?(:cover_filters) && SimpleCov.respond_to?(:filters),
           "SimpleCov's filter API moved; re-derive this pin, do not drop it"

    measured = lambda do |relative|
      path = File.join(ROOT, relative)
      # Otherwise a renamed or deleted file turns these assertions into vacuous passes.
      assert File.exist?(path), "#{relative} no longer exists — update this pin"
      file = SimpleCov::SourceFile.new(path, { "lines" => [ 1 ] })
      SimpleCov.cover_filters.any? { |f| f.matches?(file) } &&
        SimpleCov.filters.none? { |f| f.matches?(file) }
    end

    # `cover` must stay a string glob. Only globs drive SimpleCov's unloaded-file
    # injection, so an equivalent Regexp would silently drop never-loaded lib/ files
    # out of the denominator entirely and quietly raise the percentage.
    assert SimpleCov.cover_globs.any?, "cover must be configured with a string glob"

    # The decision path — the whole point of measuring this gem at all.
    assert measured.call("lib/current_scope/resolver.rb"),
           "lib/ must be measured; this is the regression the bootstrap exists to prevent"
    assert measured.call("lib/current_scope/guard.rb"), "lib/ must be measured"

    # Excluded because no test could reach them, not because they are untested.
    assert_not measured.call("lib/current_scope/version.rb"),
               "version.rb loads before coverage starts and can only ever report 0%"
    assert_not measured.call("lib/generators/current_scope/install/templates/initializer.rb"),
               "generator templates run in a host app, never here"
  end

  test "the bootstrap refuses to run after the engine has loaded" do
    # Clear COVERAGE for the duration: the guard is what is under test, and the
    # opt-out short-circuits ahead of it, so leaving an ambient COVERAGE=0 set
    # would turn the documented opt-out into a red suite.
    original = ENV.delete("COVERAGE")
    # CurrentScope::Engine is loaded by now, which is exactly the broken ordering.
    # Proves the guard actually fires rather than merely never having fired.
    # Safe to `load` a file that would otherwise start SimpleCov only because the
    # guard raises before `require "simplecov"`; keep it in that order.
    error = assert_raises(RuntimeError) { load BOOTSTRAP }
    assert_match(/ran too late/, error.message)
    assert_match(/COVERAGE=0/, error.message, "the message must name the opt-out")
  ensure
    ENV["COVERAGE"] = original
  end

  test "the coverage floor is armed only in CI" do
    skip "coverage is disabled" if ENV["COVERAGE"] == "0"

    assert SimpleCov.respond_to?(:minimum_coverage),
           "SimpleCov.minimum_coverage moved; re-derive this pin, do not drop it"

    if ENV["CI"]
      assert_equal({ line: 95, branch: 80 }, SimpleCov.minimum_coverage,
                   "CI must fail when coverage collapses; do not lower the floor to pass a PR")
    else
      assert_empty SimpleCov.minimum_coverage,
                   "a local single-file run must stay green; put CI=1 in front of the " \
                   "SIMPLECOV_COMMAND_NAME commands to reproduce the floor"
    end
  end

  test "COVERAGE=0 opts out before the too-late guard can raise" do
    original = ENV["COVERAGE"]
    ENV["COVERAGE"] = "0"
    # Same broken ordering as above; the opt-out must win, not raise.
    assert_nothing_raised { load BOOTSTRAP }
  ensure
    ENV["COVERAGE"] = original
  end
end
