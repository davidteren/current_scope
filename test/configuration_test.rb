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

    # ENV can only carry strings — the boolean modes must be spellable too.
    config.audit = "true"
    assert_equal true, config.audit
    config.audit = "false"
    assert_equal false, config.audit
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

  # --- collection_read_actions (#65) ---
  #
  # The list is matched as STRINGS against the key's action segment, so the
  # writer normalizes. A host writing the natural [:index] must not silently
  # fall back to the ticking-only branch — that would un-fix #65 with no
  # signal, which is exactly the footgun sod_actions' plain accessor has and
  # a new key need not inherit.

  test "collection reads are on by default — collection_read_actions is [index]" do
    assert_equal [ "index" ], CurrentScope::Configuration.new.collection_read_actions
  end

  test "collection_read_actions normalizes symbols so [:index] cannot silently disable the fix" do
    config = CurrentScope::Configuration.new
    config.collection_read_actions = [ :index, :export ]
    assert_equal [ "index", "export" ], config.collection_read_actions
  end

  test "a bare string wraps to a one-element list" do
    config = CurrentScope::Configuration.new
    config.collection_read_actions = "index"
    assert_equal [ "index" ], config.collection_read_actions
  end

  test "nil and [] both opt out, restoring the pre-#65 record-less semantics" do
    config = CurrentScope::Configuration.new
    config.collection_read_actions = nil
    assert_equal [], config.collection_read_actions
    config.collection_read_actions = []
    assert_equal [], config.collection_read_actions
  end

  test "a full permission key raises — the list is action-segment matched, app-wide" do
    # "reports#index" can never match the action-segment comparison, and
    # stripping it to "index" would silently widen controller-scoped intent to
    # every controller. Neither reading is honest; say so at assignment.
    config = CurrentScope::Configuration.new
    error = assert_raises(CurrentScope::ConfigurationError) do
      config.collection_read_actions = %w[reports#index export]
    end
    assert_match "reports#index", error.message
    assert_match "every controller", error.message
    assert_equal [ "index" ], config.collection_read_actions,
      "the previous list stands, like the other validating writers"
  end

  test "the stored list is frozen — in-place mutation cannot bypass the writer" do
    # config.collection_read_actions << :export would dodge normalization, the
    # keyed-member raise, and the mutating-name warning. Frozen is loud.
    config = CurrentScope::Configuration.new
    assert_raises(FrozenError) { config.collection_read_actions << "export" }
    assert_equal [ "index" ], config.collection_read_actions
  end

  test "a canonical mutating action warns loudly but is accepted" do
    config = CurrentScope::Configuration.new
    out = capture_rails_log { config.collection_read_actions = %w[index destroy] }
    assert_equal [ "index", "destroy" ], config.collection_read_actions,
      "warn, not raise — the custom-action space keeps any blocklist partial"
    assert_match "#49", out, "the warning names the escalation shape"
    assert_match '"destroy"', out
  end

  private

  def capture_rails_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end
end
