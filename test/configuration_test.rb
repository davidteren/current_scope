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

  # --- gating_tripwire posture (U5) ---
  #
  # NOT the diagnostics' emit/silence split: there, the non-dev default (false)
  # means stay quiet; here it means :warn, which EMITS. The mixin is opt-in, so
  # a production host that included it is asking for the ungated inventory —
  # the env only decides whether a hit 500s (dev/test) or logs.

  test "gating_tripwire defaults to :raise in development and test" do
    %w[development test].each do |env|
      with_rails_env(env) do
        assert_equal :raise, CurrentScope::Configuration.new.gating_tripwire,
                     "an ungated action in #{env} should go red in CI, not hide in a log"
      end
    end
  end

  test "gating_tripwire defaults to :warn outside development and test" do
    %w[staging production].each do |env|
      with_rails_env(env) do
        assert_equal :warn, CurrentScope::Configuration.new.gating_tripwire,
                     "a #{env} host that included the opt-in mixin wants the inventory, not 500s"
      end
    end
  end

  test "an unknown gating_tripwire mode raises at assignment, naming both modes" do
    config = CurrentScope::Configuration.new
    error = assert_raises(CurrentScope::ConfigurationError) { config.gating_tripwire = :nonsense }
    assert_match ":raise", error.message
    assert_match ":warn", error.message
    assert_equal :raise, config.gating_tripwire, "the previous mode stands, like enforcement="
  end

  test "bare-Ruby Configuration.new without Rails defaults gating_tripwire to :warn, no raise" do
    lib = File.expand_path("../lib", __dir__)
    out = IO.popen(
      [ RbConfig.ruby, "-I", lib, "-e",
       'require "current_scope/configuration"; print CurrentScope::Configuration.new.gating_tripwire' ],
      err: [ :child, :out ], &:read
    )
    assert_equal "warn", out, "no Rails means no env to be dev/test in — and nothing may raise"
  end
end
