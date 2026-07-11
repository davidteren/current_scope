require "test_helper"

class ConfigurationTest < ActiveSupport::TestCase
  ENV_KEY = CurrentScope::Configuration::PROD_MUTATIONS_ENV

  def with_rails_env(name)
    original = Rails.env
    Rails.env = name
    yield
  ensure
    Rails.env = original
  end

  def with_env(key, value)
    had, old = ENV.key?(key), ENV[key]
    value.nil? ? ENV.delete(key) : ENV[key] = value
    yield
  ensure
    had ? ENV[key] = old : ENV.delete(key)
  end

  test "allows impersonated mutations outside production" do
    config = CurrentScope::Configuration.new
    with_rails_env("staging") do
      with_env(ENV_KEY, nil) do
        assert_nothing_raised { config.allow_mutations_while_impersonating = true }
      end
    end
    assert config.allow_mutations_while_impersonating
  end

  test "refuses impersonated mutations in production without the env opt-in" do
    config = CurrentScope::Configuration.new
    with_rails_env("production") do
      with_env(ENV_KEY, nil) do
        assert_raises(CurrentScope::ConfigurationError) do
          config.allow_mutations_while_impersonating = true
        end
      end
    end
  end

  test "allows impersonated mutations in production with the env opt-in" do
    config = CurrentScope::Configuration.new
    with_rails_env("production") do
      with_env(ENV_KEY, "1") do
        assert_nothing_raised { config.allow_mutations_while_impersonating = true }
      end
    end
    assert config.allow_mutations_while_impersonating
  end

  test "assigning false in production is always allowed" do
    config = CurrentScope::Configuration.new
    with_rails_env("production") do
      with_env(ENV_KEY, nil) do
        assert_nothing_raised { config.allow_mutations_while_impersonating = false }
      end
    end
    assert_not config.allow_mutations_while_impersonating
  end
end
