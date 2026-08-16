# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

# SimpleCov must start before anything it measures is loaded (#114 / worklist
# T6). bin/rails already loaded this for `bin/rails test`; this call covers the
# runners that load a test file directly. See test/coverage_setup.rb.
require_relative "coverage_setup"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"

# String-keyed subject/resource model used by the #151 suites. Loaded here so the
# table is built once, before any test transaction opens.
require_relative "support/uuid_user"
require_relative "support/identity_user"

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
