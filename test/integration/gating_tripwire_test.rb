require "test_helper"

# A4: the opt-in tripwire catches an action that completed without being gated,
# on a controller that never included Guard — the case Guard's own after_action
# cannot see. It carries its OWN skip API (skip_before_action :current_scope_check!
# would raise at class load on such a controller).
class GatingTripwireTest < ActionDispatch::IntegrationTest
  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  test "an ungated action (tripwire mixin, no Guard) trips the tripwire" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      get tripwire_open_url
    end
    assert_match "current_scope_check!", error.message
  end

  test "an action marked with the mixin's own skip API does not trip" do
    get tripwire_public_url
    assert_response :success
  end

  test "a Guard'd action that ran the gate does not trip" do
    owner = User.create!(name: "Owner")
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: owner, role: role)

    get tripwire_gated_url, headers: sign_in(owner)
    assert_response :success
  end
end

# U5: the tripwire's posture. :raise (the dev/test default) is the behaviour
# above, unchanged; :warn lets a real app inventory its ungated surface without
# 500ing — one line per controller#action, re-armed on reload.
class GatingTripwireWarnModeTest < ActionDispatch::IntegrationTest
  setup do
    @original_mode = CurrentScope.config.gating_tripwire
    CurrentScope.config.gating_tripwire = :warn
    CurrentScope::GatingTripwire.reset_warnings!
  end

  teardown do
    CurrentScope.config.gating_tripwire = @original_mode
    CurrentScope::GatingTripwire.reset_warnings!
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  # Same shape as DiagnosticsLogCapture (dev_diagnostics_test.rb) — inlined so
  # this file still runs standalone via -Itest.
  def capture_log
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.level = Logger::WARN }
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def trips(log) = log.scan(/completed without running current_scope_check!/)

  test "an ungated action responds normally and logs a warning naming controller#action" do
    log = nil
    assert_nothing_raised { log = capture_log { get tripwire_open_url } }

    assert_response :success
    assert_equal 1, trips(log).size
    assert_match "tripwire_ungated#open", log
  end

  test "the warning carries the same remediation as the raise" do
    log = capture_log { get tripwire_open_url }

    assert_match "CurrentScope::Guard", log
    assert_match "current_scope_skip_tripwire!", log
  end

  test "warns once per site: same action once, a different ungated action again" do
    log = capture_log do
      get tripwire_open_url
      get tripwire_open_url
    end
    assert_equal 1, trips(log).size, "two requests to the same ungated action, one line"

    log = capture_log { get conditional_skip_tripwire_url }
    assert_equal 1, trips(log).size,
                 "a DIFFERENT ungated site gets its own line — this is an inventory, not a per-process nag"
  end

  test "a dev reload (engine to_prepare) re-arms a warned site" do
    assert_equal 1, trips(capture_log { get tripwire_open_url }).size
    assert_empty trips(capture_log { get tripwire_open_url }), "latched"

    # Run the REAL to_prepare callbacks — the engine wiring is the thing under
    # test; calling reset_warnings! directly would stay green with the wiring
    # dropped. The scopeable registry is rebuilt by class load, which test env
    # never redoes, so put it back by hand.
    registered = CurrentScope.scopeable_registry.dup
    Rails.application.reloader.prepare!
    registered.each { |name| CurrentScope.register_scopeable(name) }

    assert_equal 1, trips(capture_log { get tripwire_open_url }).size,
                 "a reload can change whether a site is gated — a stale latch is a false all-clear"
  end

  test "the conditional-skip residual: the only:-skipped action warns, the gated one stays silent" do
    # Anonymous request — #index skips the gate, so it renders AND warns.
    log = capture_log { get conditional_skip_tripwire_url }
    assert_response :success
    assert_match "conditional_skip_tripwire#index", log

    owner = User.create!(name: "Owner")
    role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: owner, role: role)

    log = capture_log { get conditional_skip_tripwire_show_url, headers: sign_in(owner) }
    assert_response :success
    assert_empty trips(log), "#show ran the gate; nothing to warn about"
  end

  test "the mixin's own skip API still exempts under :warn" do
    log = capture_log { get tripwire_public_url }

    assert_response :success
    assert_empty trips(log)
  end

  test "a report-mode pass does not trip the tripwire" do
    CurrentScope.config.enforcement = :report
    nobody = User.create!(name: "Nobody") # signed in, granted nothing

    log = capture_log { get tripwire_gated_url, headers: sign_in(nobody) }

    assert_response :success, "report mode let the missing grant through"
    assert_empty trips(log),
                 "the gate RAN (that is what report mode is) — the tripwire has nothing to say"
  ensure
    CurrentScope.config.enforcement = :enforce
  end
end
