require "test_helper"

# The refusal text is the product when the guard stops a boot. These examples
# pin both database_context branches and both env_prefix branches.
class SchemaGuardTest < ActiveSupport::TestCase
  test "database_context names the environment and the database" do
    text = CurrentScope::SchemaGuard.send(:database_context, CurrentScope::Role)
    name = CurrentScope::Role.connection_pool.db_config.database

    assert_includes text, Rails.env
    assert_includes text, name.inspect
    assert_equal "the #{Rails.env} database #{name.inspect}", text
  end

  test "database_context keeps the environment when the name cannot be read" do
    model = Class.new do
      def self.connection_pool
        raise "unreadable database name"
      end
    end

    assert_equal "the #{Rails.env} database", CurrentScope::SchemaGuard.send(:database_context, model)
    assert_no_match(/unreadable/, CurrentScope::SchemaGuard.send(:database_context, model))
  end

  test "env_prefix is empty in development" do
    with_rails_env("development") do
      assert_equal "", CurrentScope::SchemaGuard.send(:env_prefix)
      assert_no_match(/RAILS_ENV=development/, CurrentScope::SchemaGuard.send(:env_prefix))
    end
  end

  test "env_prefix names a non-development environment and keeps the trailing space" do
    with_rails_env("test") do
      assert_equal "RAILS_ENV=test ", CurrentScope::SchemaGuard.send(:env_prefix)
    end
  end

  def with_rails_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end
end
