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

  test "test_helper requires the bootstrap for runners that skip bin/rails" do
    source = File.read(File.join(__dir__, "test_helper.rb"))
    assert_match %r{require_relative ["']coverage_setup["']}, source,
                 "test_helper must require the bootstrap too — `ruby -Itest foo_test.rb` " \
                 "never touches bin/rails, and would record no coverage at all"
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

  test "COVERAGE=0 opts out before the too-late guard can raise" do
    original = ENV["COVERAGE"]
    ENV["COVERAGE"] = "0"
    # Same broken ordering as above; the opt-out must win, not raise.
    assert_nothing_raised { load BOOTSTRAP }
  ensure
    ENV["COVERAGE"] = original
  end
end
