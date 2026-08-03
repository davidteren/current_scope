# frozen_string_literal: true

# Coverage bootstrap (#114 / worklist T6). Loaded by BOTH test entry points,
# because Ruby's Coverage library only instruments files loaded after it starts:
#
#   * bin/rails, before `require "rails/engine/commands"`. That line loads
#     ENGINE_PATH, which pulls in all of lib/current_scope — so starting from
#     test_helper alone reported the whole engine at 0% while still counting its
#     lines in the total. Every `bin/rails test` run measured only app/.
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
  skip %r{/test/}
  skip %r{/dummy/}
  # No minimum_coverage until a baseline is established from CI runs.
end
