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

# The issue's repro, end to end (#21): build the documented "trusted admin may
# self-approve" role using ONLY the shipped UI — no full_access, no console
# insert — and prove break-glass then works. Every test above grants
# reports#bypass_sod with a direct role_permissions insert, which is exactly the
# console workaround this closes: the feature worked, but nobody could reach it.
class BreakGlassGrantableThroughUiTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob) # @bob is the initiator

    @original_sod_actions = CurrentScope.config.sod_actions
    @original_allow_bypass = CurrentScope.config.allow_sod_bypass
    CurrentScope.config.sod_actions = %w[approve]
    CurrentScope.config.allow_sod_bypass = true
    # The catalog is memoized and derived from config, so a runtime flip needs a
    # rebuild — and needs one again on the way out, or the injected keys leak
    # into every test that runs after this one.
    CurrentScope.reset_catalog!
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
    CurrentScope.config.allow_sod_bypass = @original_allow_bypass
    CurrentScope.reset_catalog!
    Report.sod_bypass_glass = false
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  # These tests drive the mounted engine (the role form) and THEN the host app
  # (the gated action). After an engine request the integration session keeps the
  # engine's SCRIPT_NAME, so a host url helper — even through main_app — builds
  # /current_scope/reports/1/approve and 404s. Pin the host mount explicitly.
  def approve_url(report) = approve_report_url(report, script_name: "")

  test "the role editor renders a bypass_sod cell for a controller that routes an SoD action" do
    role = CurrentScope::Role.create!(name: "Breaker")

    get current_scope.edit_role_url(role), headers: sign_in(@owner)
    assert_response :success
    # The exact inversion of the issue's confirming assertion: this used to be
    # refute_includes — there was no cell to tick anywhere in the UI.
    assert_select "input[value=?]", "reports#bypass_sod", count: 1
  end

  test "granting bypass_sod through the role form persists it, and break-glass then works" do
    role = CurrentScope::Role.create!(name: "Breaker")

    # 1. Tick the cell — exactly what the grid form POSTs.
    patch current_scope.role_url(role), headers: sign_in(@owner),
          params: { role: { name: "Breaker", full_access: "0",
                            permission_keys: [ "", "reports#approve", "reports#bypass_sod" ] } }
    assert_redirected_to current_scope.roles_url
    assert role.reload.grants?("reports#bypass_sod"), "the grant must survive the save, not be scrubbed"

    # 2. Give it to the initiator. No full_access anywhere.
    CurrentScope::RoleAssignment.create!(subject: @bob, role: role)
    assert_not CurrentScope.resolver.full_access?(@bob), "this must not be a full_access role in disguise"

    # 3. Break the glass on their own record.
    Report.sod_bypass_glass = true
    assert_difference -> { CurrentScope::Event.where(event: "sod.bypassed").count }, 1 do
      post approve_url(@report), headers: sign_in(@bob)
    end
    assert_response :success
    assert_equal "sod_bypassed", response.headers["X-Current-Scope-Reason"]
  end

  test "the veto still stands for the same UI-granted role when the glass is intact" do
    role = CurrentScope::Role.create!(name: "Breaker")
    patch current_scope.role_url(role), headers: sign_in(@owner),
          params: { role: { name: "Breaker", full_access: "0",
                            permission_keys: [ "reports#approve", "reports#bypass_sod" ] } }
    CurrentScope::RoleAssignment.create!(subject: @bob, role: role)

    # Holding the permission is not the bypass — the record must opt in too.
    Report.sod_bypass_glass = false
    post approve_url(@report), headers: sign_in(@bob)
    assert_response :forbidden
    assert_equal "sod_veto", response.headers["X-Current-Scope-Reason"]
  end
end

# With break-glass off, the permission is not grantable at all — grantability
# follows the catalog, and the catalog follows the flag. This is the pre-#21
# behavior, now scoped to the flag being off rather than being unconditional.
class BreakGlassUngrantableWhenOffTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @original_allow_bypass = CurrentScope.config.allow_sod_bypass
    @original_sod_actions = CurrentScope.config.sod_actions
    CurrentScope.config.allow_sod_bypass = false
    CurrentScope.config.sod_actions = %w[approve]
    CurrentScope.reset_catalog!
  end

  teardown do
    CurrentScope.config.allow_sod_bypass = @original_allow_bypass
    CurrentScope.config.sod_actions = @original_sod_actions
    CurrentScope.reset_catalog!
  end

  def sign_in(user) = { "X-User-Id" => user.id.to_s }

  test "no bypass cell renders and the key cannot be granted when break-glass is off" do
    role = CurrentScope::Role.create!(name: "Breaker")

    get current_scope.edit_role_url(role), headers: sign_in(@owner)
    assert_select "input[value=?]", "reports#bypass_sod", count: 0

    # And it is rejected rather than silently dropped — #20's doing.
    patch current_scope.role_url(role), headers: sign_in(@owner),
          params: { role: { name: "Breaker", full_access: "0",
                            permission_keys: [ "reports#bypass_sod" ] } }
    assert_response :unprocessable_entity
    assert_not role.reload.grants?("reports#bypass_sod")
  end
end
