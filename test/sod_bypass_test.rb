require "test_helper"

# Break-glass override (config.allow_sod_bypass): a privileged, audited waiver of
# the SoD veto for a specific record. The RESOLVER half — it lifts the veto under
# a live three-way AND and reports :sod_bypassed, staying pure (no writes). The
# audit write is the Guard's job (see test/guard_sod_bypass_test.rb).
class SodBypassTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob) # @bob is the initiator

    @original_sod_actions = CurrentScope.config.sod_actions
    @original_sod_identity = CurrentScope.config.sod_identity
    @original_allow_bypass = CurrentScope.config.allow_sod_bypass
    CurrentScope.config.sod_actions = %w[approve]
    CurrentScope.config.allow_sod_bypass = true
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
    CurrentScope.config.sod_identity = @original_sod_identity
    CurrentScope.config.allow_sod_bypass = @original_allow_bypass
  end

  def assign(user, role)
    CurrentScope::RoleAssignment.create!(subject: user, role: role)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  # A Report that opts into break-glass, returning `flag` from the host hook.
  def bypassable(report, flag)
    report.define_singleton_method(:current_scope_sod_bypassed?) { flag }
    report
  end

  def approve(subject, record, actor: nil)
    @resolver.decide(subject: subject, permission: "reports#approve", record: record, actor: actor)
  end

  test "happy path: conflict + config on + hook true + initiator holds bypass grants, reason :sod_bypassed" do
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    assert_equal [ true, :sod_bypassed ], approve(@bob, bypassable(@report, true))
    assert @resolver.allow?(subject: @bob, permission: "reports#approve", record: bypassable(@report, true))
  end

  test "config off (default): the veto is absolute even with hook + privilege" do
    CurrentScope.config.allow_sod_bypass = false
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    assert_equal [ false, :sod_veto ], approve(@bob, bypassable(@report, true))
  end

  test "hook false: veto stands" do
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    assert_equal [ false, :sod_veto ], approve(@bob, bypassable(@report, false))
  end

  test "hook absent: fail-closed (no raise), veto stands" do
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    # A record type that doesn't define the hook at all — undef it so respond_to?
    # is false — must be treated as never-bypassed, with no raise.
    @report.singleton_class.send(:undef_method, :current_scope_sod_bypassed?)
    assert_not @report.respond_to?(:current_scope_sod_bypassed?)
    assert_equal [ false, :sod_veto ], approve(@bob, @report)
  end

  test "initiator lacks the bypass permission: veto stands" do
    assert_equal [ false, :sod_veto ], approve(@bob, bypassable(@report, true))
  end

  test "no conflict: a non-initiator's approve is a normal allow, never :sod_bypassed" do
    assign(@alice, role("Reviewer", "reports#approve"))
    assert_equal [ true, nil ], approve(@alice, bypassable(@report, true))
  end

  test "non-SoD action: the bypass path is never consulted" do
    CurrentScope.config.sod_actions = [] # approve is no longer an SoD action
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    # No veto and no bypass reason — it resolves normally (and denies: bob has no approve grant).
    assert_equal [ false, :no_grant ], approve(@bob, bypassable(@report, true))
  end

  test "impersonation :either lifts only for the initiating identity that holds the permission (no laundering)" do
    CurrentScope.config.sod_identity = :either
    # @bob initiated the report; the session impersonates @alice (subject) with @bob as the real actor.
    # Granting the SUBJECT the bypass must NOT launder it — the INITIATOR (@bob) must hold it.
    assign(@alice, role("Breaker", "reports#bypass_sod"))
    assert_equal [ false, :sod_veto ], approve(@alice, bypassable(@report, true), actor: @bob)

    assign(@bob, role("BreakerB", "reports#bypass_sod"))
    assert_equal [ true, :sod_bypassed ], approve(@alice, bypassable(@report, true), actor: @bob)
  end

  test "the bypass decision is pure — no audit rows written by the resolver" do
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    assert_no_difference -> { CurrentScope::Event.count } do
      @resolver.allow?(subject: @bob, permission: "reports#approve", record: bypassable(@report, true))
    end
  end

  test "re-entrancy is bounded: granting bypass_sod does not loop or raise" do
    assign(@bob, role("Breaker", "reports#bypass_sod"))
    assert_nothing_raised { approve(@bob, bypassable(@report, true)) }
  end

  test "a bypass permission that is itself an SoD action is refused loudly (recursion guard)" do
    @original_bypass_permission = CurrentScope.config.sod_bypass_permission
    CurrentScope.config.sod_bypass_permission = "approve" # also in sod_actions → would recurse
    assign(@bob, role("Breaker", "reports#approve"))
    error = assert_raises(CurrentScope::ConfigurationError) { approve(@bob, bypassable(@report, true)) }
    assert_match "must not be an SoD action", error.message
  ensure
    CurrentScope.config.sod_bypass_permission = @original_bypass_permission
  end
end
