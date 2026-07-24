# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# SimpleCov must start before the app is required (#114 / worklist T6).
# Default on in CI and local; set COVERAGE=0 to skip.
unless ENV["COVERAGE"] == "0"
  require "simplecov"
  # CI sets unit/system so the two runs merge. Local default is a stable
  # name so re-runs replace the previous result instead of stacking PIDs.
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
end

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end

# CurrentAttributes only resets around the executor (requests/jobs), not around
# plain unit tests — so CurrentScope::Current can leak between them. Reset it
# after every test for isolation. (Latent everywhere; surfaced by the Rails-8.0
# floor run's different test order.)
class ActiveSupport::TestCase
  teardown { CurrentScope::Current.reset }
end
