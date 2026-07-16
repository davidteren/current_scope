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

  test "SoD is opt-in — sod_actions is empty by default" do
    assert_empty CurrentScope::Configuration.new.sod_actions
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

  # --- env opt-in value semantics ---
  #
  # The env var's VALUE means what it says: an operator writing `…=false` in a
  # deploy manifest must NOT silently enable the escape hatch.

  test "a falsy env value ('false', '0', '') does not opt production in" do
    [ "false", "0", "FALSE", "off", "" ].each do |falsy|
      config = CurrentScope::Configuration.new
      with_rails_env("production") do
        with_env(ENV_KEY, falsy) do
          assert_raises(CurrentScope::ConfigurationError, "#{falsy.inspect} must read as not-opted-in") do
            config.allow_mutations_while_impersonating = true
          end
        end
      end
    end
  end

  test "a truthy env value ('true') opts production in, like '1'" do
    config = CurrentScope::Configuration.new
    with_rails_env("production") do
      with_env(ENV_KEY, "true") do
        assert_nothing_raised { config.allow_mutations_while_impersonating = true }
      end
    end
    assert config.allow_mutations_while_impersonating
  end

  # --- audit / sod_identity validating writers ---
  #
  # Both are read with narrow comparisons (`== :strict`, `== :either`), so a
  # typo would silently degrade in the security-weakening direction. Same
  # contract as enforcement=: raise at assignment, the previous mode stands.

  test "audit accepts its closed set, symbol or string" do
    config = CurrentScope::Configuration.new
    [ false, true, :strict ].each do |mode|
      assert_nothing_raised { config.audit = mode }
      assert_equal mode, config.audit
    end
    config.audit = "strict"
    assert_equal :strict, config.audit, "a String must work so ENV[\"...\"] can set it"
  end

  test "a misspelled audit mode raises at assignment instead of acting as plain true" do
    config = CurrentScope::Configuration.new
    config.audit = :strict
    error = assert_raises(CurrentScope::ConfigurationError) { config.audit = :strixt }
    assert_match ":strict", error.message
    assert_equal :strict, config.audit, "the previous mode stands, like enforcement="
  end

  test "sod_identity accepts its closed set, symbol or string" do
    config = CurrentScope::Configuration.new
    %i[either subject].each do |mode|
      assert_nothing_raised { config.sod_identity = mode }
      assert_equal mode, config.sod_identity
    end
    config.sod_identity = "either"
    assert_equal :either, config.sod_identity
  end

  test "an unknown sod_identity raises instead of silently narrowing the veto to :subject" do
    config = CurrentScope::Configuration.new
    error = assert_raises(CurrentScope::ConfigurationError) { config.sod_identity = :both }
    assert_match ":either", error.message
    assert_match ":subject", error.message
    assert_equal :either, config.sod_identity, "the default stands"
  end
end
