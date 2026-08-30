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

# #183: `current_scope_grantable_roles` is a class-level instance variable, so a
# declaration made in a test outlives the transactional rollback and leaks into
# every later test in the process. Tests declare through this helper, which
# restores exactly what was there before — no file has to keep a hand-written
# list of the classes it touched (#183 review).
module CurrentScope
  module GrantableRolesIsolation
    IVAR = :@current_scope_grantable_roles

    def declare_grantable_roles(klass, names)
      @grantable_roles_snapshots ||= {}
      @grantable_roles_snapshots[klass] ||=
        [ klass.instance_variable_defined?(IVAR), klass.instance_variable_get(IVAR) ]
      klass.current_scope_grantable_roles = names
    end

    def restore_grantable_roles!
      (@grantable_roles_snapshots || {}).each do |klass, (declared, value)|
        if declared
          klass.instance_variable_set(IVAR, value)
        elsif klass.instance_variable_defined?(IVAR)
          klass.send(:remove_instance_variable, IVAR)
        end
      end
      @grantable_roles_snapshots = nil
    end
  end
end

class ActiveSupport::TestCase
  include CurrentScope::GrantableRolesIsolation
  teardown { restore_grantable_roles! }
end
