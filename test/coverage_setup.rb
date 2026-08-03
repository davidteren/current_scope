# Coverage bootstrap (#114 / worklist T6). Loaded by BOTH test entry points,
# because Ruby's Coverage library only instruments files loaded after it starts:
#
#   * bin/rails, before its `require "rails/engine/commands"`. Dispatching a
#     test command from there loads the engine and the dummy app, so starting
#     from test_helper alone reported the whole engine at 0% while still
#     counting its lines in the total. Every `bin/rails test` measured only app/.
#   * test/test_helper.rb, for runners that load a test file directly
#     (`ruby -Itest test/foo_test.rb`, some IDE runners) and never touch
#     bin/rails.
#
# `require_relative` is idempotent, so whichever entry point comes first starts
# SimpleCov exactly once and the other is a no-op.
#
# NOT named coverage.rb: `ruby -Itest` puts this directory on the load path, and
# SimpleCov itself calls `require "coverage"` to load the stdlib extension that
# does the measuring. A test/coverage.rb wins that lookup, so SimpleCov gets
# this file back instead of the extension and dies on `uninitialized constant
# SimpleCov::Coverage`.
#
# Set COVERAGE=0 to skip.
return if ENV["COVERAGE"] == "0"

# The whole point of this file is WHEN it runs, and nothing else in the suite
# fails if that ordering breaks — the tests still pass, the number just silently
# drops back to ~35%. So assert the ordering here, loudly. `CurrentScope::Engine`
# is defined only once the engine has loaded; the gemspec's `version.rb` does not
# define it, so this stays quiet on the legitimate paths.
#
# A plain RuntimeError on purpose, not `CurrentScope::ConfigurationError`: this runs
# before the engine is loaded, so that class does not exist yet. Keep this block
# above `require "simplecov"` — test/coverage_setup_test.rb loads this file to prove
# the guard fires, which is only safe while nothing starts SimpleCov before it.
if defined?(CurrentScope::Engine)
  raise "Coverage bootstrap ran too late: CurrentScope::Engine is already loaded, " \
        "so Ruby's Coverage cannot instrument lib/ and the reported figure will be " \
        "far too low. Require test/coverage_setup.rb BEFORE the engine loads " \
        "(bin/rails does this above its `require \"rails/engine/commands\"`), or set " \
        "COVERAGE=0 to opt out."
end

require "simplecov"

# CI sets unit/system so the two runs merge. Local default is a stable name so
# re-runs replace the previous result instead of stacking PIDs.
SimpleCov.command_name ENV.fetch("SIMPLECOV_COMMAND_NAME", "minitest")

SimpleCov.start do
  enable_coverage :branch
  root File.expand_path("..", __dir__)
  # SimpleCov 1.x (pinned 1.0.2): cover = include + track unloaded files;
  # skip = exclude. See simplecov/configuration/filters.rb.
  cover "{app,lib}/**/*.rb"
  # NOTE ON PATTERNS: SimpleCov matches filters against `project_filename`, which is
  # root-relative with NO leading slash ("lib/current_scope/version.rb"). A pattern
  # written as %r{/lib/...} therefore never matches and fails silently. Anchor with \A.
  # (The previous `skip %r{/test/}` here was dead for exactly that reason; it is gone,
  # and the `cover` glob above already restricts the set to app/ and lib/ anyway.)
  #
  # Both exclusions below are lines no test could ever reach, for different reasons.
  # Generator templates are host-app code, copied out and executed there, never here:
  skip %r{\Alib/generators/.*/templates/}
  # version.rb is shipped runtime code that the tool cannot see rather than code
  # nothing exercises: `require "bundler/setup"` evaluates the gemspec, which
  # require_relatives it, so it is always loaded before any bootstrap could start and
  # can only ever report 0%. If real logic is ever added there, it will not be measured.
  skip %r{\Alib/current_scope/version\.rb\z}
  # Merging `unit` into `system` must not depend on how long the two runs are apart.
  # The 600s default silently drops the earlier result and reports the later run
  # alone — a wrong number with only a warning, which is the failure class this
  # whole file exists to prevent.
  merge_timeout 3600
  # No minimum_coverage yet — tracked in #146.
end
