# frozen_string_literal: true

require "test_helper"
require "yaml"

# Pins the mutation-testing gate's wiring. The workflow and config can rot
# without any suite noticing — a missing COVERAGE=0, a `since: none`, or a
# boot path that is not the dummy app would either fail CI for the wrong
# reason or silently skip the product. This test is the same shape as
# test/coverage_setup_test.rb: assert the files, not a full Mutineer run.
class MutineerConfigTest < ActiveSupport::TestCase
  ROOT = File.expand_path("..", __dir__)
  CONFIG = File.join(ROOT, ".mutineer.yml")
  WORKFLOW = File.join(ROOT, ".github/workflows/mutation.yml")
  # Keep in lockstep with Mutineer::Config::KNOWN_KEYS. Duplicated here so
  # this pin does not load the mutineer gem (hosts do not need it; the
  # gemspec does not declare it).
  KNOWN_KEYS = %w[
    operators jobs threshold only require boot rails since framework
    verbose ignore baseline fail_fast test_command daemon
  ].freeze

  test ".mutineer.yml boots the dummy app and keeps a first-adoption floor" do
    raw = YAML.safe_load_file(CONFIG)
    assert raw.is_a?(Hash), ".mutineer.yml must be a mapping"

    unknown = raw.keys.map(&:to_s) - KNOWN_KEYS
    assert_empty unknown, "unknown Mutineer config key(s): #{unknown.join(', ')}"

    assert_equal true, raw["rails"]
    assert_not_equal true, raw["daemon"],
                     "--daemon needs db/schema.rb at the repo root; this engine's " \
                     "schema is test/dummy/db/schema.rb (#227)"
    config_src = File.read(CONFIG)
    assert_match(%r{issues/227}, config_src,
                 "daemon deferral must cite https://github.com/davidteren/current_scope/issues/227")
    assert_equal "test/mutineer_boot.rb", raw["boot"]
    boot_src = File.read(File.join(ROOT, raw["boot"]))
    assert_includes boot_src, 'require_relative "dummy/config/environment"'
    assert_includes boot_src, 'require_relative "coverage_setup"',
                    "mutineer_boot is a test entry point — require coverage_setup " \
                    "before the dummy app (COVERAGE=0 makes it a no-op start)"
    assert_includes boot_src, "$LOAD_PATH.unshift",
                    "the boot file must put test/ on $LOAD_PATH or " \
                    "`require \"test_helper\"` fails under Mutineer"
    assert_includes boot_src, 'ENV["COVERAGE"] = "0"'
    assert boot_src.index('ENV["COVERAGE"] = "0"') < boot_src.index('require_relative "coverage_setup"'),
           "COVERAGE=0 must be set before coverage_setup is required"
    assert_equal 80, raw["threshold"]
    assert_not raw.key?("since"),
               "do not put since: in .mutineer.yml — the Action scopes PRs to " \
               "the base commit, and a file-level since would fight that"
  end

  test "the mutation workflow is a PR-scoped bundler/rails run" do
    # Psych treats YAML 1.1 `on:` as the boolean true, so pin the trigger
    # from source text and parse the rest of the file after renaming that key.
    source = File.read(WORKFLOW)
    assert_match(/^on:\n  pull_request:\n\njobs:/, source)
    assert_no_match(/^\s+paths:/, source)
    assert_no_match(/^\s+since:\s*["']?none["']?/, source)
    assert_no_match(/--no-since/, source)

    raw = YAML.safe_load(source.sub(/^on:/, "triggers:"))
    job = raw.dig("jobs", "mutineer")
    assert job, "the check name must stay `mutineer` (branch protection)"
    assert_equal "0", job.dig("env", "COVERAGE"),
                 "COVERAGE=0 is required so SimpleCov does not steal Coverage " \
                 "or apply the CI floor to a subset run"

    checkout = job.fetch("steps").find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
    assert checkout, "mutation.yml must check out the repo"
    assert_equal 0, checkout.dig("with", "fetch-depth"),
                 "fetch-depth: 0 keeps the PR base reachable for --since"

    run = job.fetch("steps").find { |step| step["uses"].to_s.start_with?("davidteren/mutineer@") }
    assert run, "mutation.yml must use davidteren/mutineer"
    assert_equal "davidteren/mutineer@v1", run["uses"]

    inputs = run.fetch("with")
    assert_equal true, truthy?(inputs["use-bundler"])
    assert_equal true, truthy?(inputs["rails"])
    assert_equal "80", inputs["threshold"].to_s
    assert_includes inputs["sources"], "lib/current_scope"
    assert_includes inputs["sources"], "app"
    extra = inputs["extra-args"].to_s
    assert_includes extra, "--boot test/mutineer_boot.rb"
    assert_not extra.include?("--daemon"),
               "--daemon is off until Mutineer can load test/dummy/db/schema.rb (#227)"
  end

  test "mutineer is a test-only Gemfile dependency, not a gemspec runtime dep" do
    gemfile = File.read(File.join(ROOT, "Gemfile"))
    assert_match(/gem ["']mutineer["']/, gemfile)

    spec = Gem::Specification.load(File.join(ROOT, "current_scope.gemspec"))
    names = spec.dependencies.map(&:name)
    assert_not_includes names, "mutineer",
                        "hosts must not pull mutineer; keep it in the Gemfile test group"

    lock = File.read(File.join(ROOT, "Gemfile.lock"))
    version = lock[/^    mutineer \(([\d.]+)\)/, 1]
    assert version, "Gemfile.lock must resolve mutineer"
    assert Gem::Version.new(version) >= Gem::Version.new("1.0.0"),
           "davidteren/mutineer@v1 PR scoping needs mutineer >= 1.0.0 (got #{version})"
  end

  test "bin/mutineer-test-files lists engine tests and omits unfit files" do
    script = File.join(ROOT, "bin/mutineer-test-files")
    assert File.executable?(script), "bin/mutineer-test-files must be executable"

    paths = Dir.chdir(ROOT) { `#{script}`.split("\n") }
    assert_operator paths.size, :>, 10
    paths.each do |path|
      assert path.start_with?("test/"), path
      assert path.end_with?("_test.rb"), path
      assert_not path.start_with?("test/system/"),
                 "system tests are too slow for mutation CI: #{path}"
      assert_not path.start_with?("test/dummy/"), path
      assert_not path.start_with?("test/generators/"),
                 "generator tests fail under Mutineer --rails boot: #{path}"
      assert File.file?(File.join(ROOT, path)), "listed test is missing: #{path}"
    end
    assert_includes paths, "test/resolver_test.rb"
    assert_includes paths, "test/integration/guard_test.rb"

    %w[
      test/docs_site_test.rb
      test/docs_site_ai_test.rb
      test/gemspec_test.rb
      test/coverage_setup_test.rb
      test/upgrading_doc_test.rb
      test/mutineer_config_test.rb
    ].each do |path|
      assert_not_includes paths, path,
                          "#{path} cannot kill engine-source mutants (and some fail under Mutineer boot)"
    end
  end

  private
    def truthy?(value)
      value == true || value.to_s == "true"
    end
end
