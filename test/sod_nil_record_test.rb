require "test_helper"

# A5: characterize the nil-record SoD asymmetry (prod behavior, unchanged) and
# cover the dev nudge (on by default in dev/test since #41, off in production).
# A present record with a missing initiator hook
# raises loud; an ABSENT record on an SoD member action skips the veto silently.
# The README member-action contract is the load-bearing control; the nudge is a
# dev/test aid.
class SodNilRecordTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob) # @bob is the initiator
    @reviewer = CurrentScope::Role.create!(name: "Reviewer")
    @reviewer.role_permissions.create!(permission_key: "reports#approve")
    CurrentScope::RoleAssignment.create!(subject: @bob, role: @reviewer)

    @original_sod_actions = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
  end

  test "present record: the initiator is vetoed (loud, correct)" do
    assert_not @resolver.allow?(subject: @bob, permission: "reports#approve", record: @report)
  end

  test "absent record: the SoD veto is silently skipped (the fail-open we document against)" do
    # Same subject who is the initiator, but no record reaches the resolver → the
    # veto bails and the org-wide grant lets them through. Prod behavior; pinned
    # so it stays intentional, and documented as member-action misuse.
    assert @resolver.allow?(subject: @bob, permission: "reports#approve", record: nil)
  end
end

# The nudge fires at the Guard seam (a real request), only when opted in.
class SodNilRecordNudgeTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(name: "Approver")
    role = CurrentScope::Role.create!(name: "Approver")
    role.role_permissions.create!(permission_key: "sod_nil#approve")
    role.role_permissions.create!(permission_key: "reports#index")
    CurrentScope::RoleAssignment.create!(subject: @user, role: role)

    @original_sod_actions = CurrentScope.config.sod_actions
    @original_warn = CurrentScope.config.warn_on_nil_sod_record
    CurrentScope.config.sod_actions = %w[approve]
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
    CurrentScope.config.warn_on_nil_sod_record = @original_warn
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  def capture_logs
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  test "nudge fires on an allowed SoD action gated with a nil record" do
    CurrentScope.config.warn_on_nil_sod_record = true
    logs = capture_logs { post "/sod_nil/approve", headers: sign_in(@user) }
    assert_response :success
    assert_match "separation-of-duties action but was gated with a nil record", logs
  end

  test "nudge stays silent when the flag is disabled" do
    CurrentScope.config.warn_on_nil_sod_record = false
    logs = capture_logs { post "/sod_nil/approve", headers: sign_in(@user) }
    assert_response :success
    assert_no_match(/separation-of-duties action but was gated/, logs)
  end

  test "nudge does not fire for a non-SoD nil-record action" do
    CurrentScope.config.warn_on_nil_sod_record = true
    logs = capture_logs { get "/reports", headers: sign_in(@user) } # index, not in sod_actions
    assert_response :success
    assert_no_match(/separation-of-duties action but was gated/, logs)
  end

  # #74 — a hook returning params[:id] (String) skips the veto; the nudge must
  # fire via resolver.sod_veto_skipped?, not a private nil/NO_RECORD copy.
  test "nudge fires when the record hook returns a String (params[:id] shape)" do
    CurrentScope.config.warn_on_nil_sod_record = true
    role = CurrentScope::Role.find_by!(name: "Approver")
    role.role_permissions.find_or_create_by!(permission_key: "sod_string#approve")

    logs = capture_logs { post "/sod_string/approve", headers: sign_in(@user) }
    assert_response :success
    assert_match "separation-of-duties action but was gated", logs
    assert_match "non-record", logs
    assert_match "String", logs
  end
end
