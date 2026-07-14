require "test_helper"

# Break-glass at the enforcement gate (KTD-1): the Guard — never the pure
# resolver, never an advisory allowed_to? — records exactly one sod.bypassed
# event and surfaces X-Current-Scope-Reason when it permits a bypassed mutation.
class GuardSodBypassTest < ActionDispatch::IntegrationTest
  setup do
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob) # @bob is the initiator

    @original_sod_actions = CurrentScope.config.sod_actions
    @original_allow_bypass = CurrentScope.config.allow_sod_bypass
    @original_audit = CurrentScope.config.audit
    CurrentScope.config.sod_actions = %w[approve]
    CurrentScope.config.allow_sod_bypass = true
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
    CurrentScope.config.allow_sod_bypass = @original_allow_bypass
    CurrentScope.config.audit = @original_audit
    Report.sod_bypass_glass = false
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }
  def assign(user, role) = CurrentScope::RoleAssignment.create!(subject: user, role: role)

  def role(name, *keys)
    r = CurrentScope::Role.create!(name: name)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  test "a bypassed mutation is permitted, records exactly one sod.bypassed event, and sets the header" do
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    Report.sod_bypass_glass = true

    assert_difference -> { CurrentScope::Event.count }, 1 do
      post approve_report_url(@report), headers: sign_in(@bob)
    end
    assert_response :success
    assert_equal "sod_bypassed", response.headers["X-Current-Scope-Reason"]

    event = CurrentScope::Event.order(:id).last
    assert_equal "sod.bypassed", event.event
    assert_equal @report.to_gid.to_s, event.target
    assert_equal "reports#approve", event.details["permission"]
    assert_equal @bob.to_gid.to_s, event.details["initiator"]
  end

  test "with the flag off, self-approval is still vetoed — no event, sod_veto header" do
    CurrentScope.config.allow_sod_bypass = false
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    Report.sod_bypass_glass = true

    assert_no_difference -> { CurrentScope::Event.count } do
      post approve_report_url(@report), headers: sign_in(@bob)
    end
    assert_response :forbidden
    assert_equal "sod_veto", response.headers["X-Current-Scope-Reason"]
  end

  test "a normal (non-bypassed) allow records no sod.bypassed event and no bypass header" do
    # @alice didn't initiate the report, so her approve is an ordinary allow.
    assign(@alice, role("Reviewer", "reports#approve"))
    post approve_report_url(@report), headers: sign_in(@alice)
    assert_response :success
    assert_nil response.headers["X-Current-Scope-Reason"]
    assert_equal 0, CurrentScope::Event.where(event: "sod.bypassed").count
  end

  test "audit off: the bypass is still permitted but records nothing" do
    CurrentScope.config.audit = false
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    Report.sod_bypass_glass = true

    assert_no_difference -> { CurrentScope::Event.count } do
      post approve_report_url(@report), headers: sign_in(@bob)
    end
    assert_response :success
    assert_equal "sod_bypassed", response.headers["X-Current-Scope-Reason"]
  end
end
