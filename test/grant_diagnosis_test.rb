require "test_helper"

# U1 of plan 032 (#134). The one place that judges a scoped grant.
#
# The load-bearing test here is the one that says NOTHING: a Report grant whose
# role ticks only `nested_reports#index` is a WORKING grant, and the obvious
# route-key heuristic would call it dead. Telling an operator to remove a
# working grant is worse than the silence this feature replaces.
class GrantDiagnosisTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(name: "Subject")
    @report = Report.create!(title: "Q3", requested_by: @user)
    @project = Project.create!(name: "P7")
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: "#{name}-#{rand(10**9)}", full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def grant(role, resource)
    CurrentScope::ScopedRoleAssignment.create!(subject: @user, role: role, resource: resource)
  end

  # --- R1: the proven verdict ---

  test "a role ticking no permissions can never match anything" do
    assert_equal :no_permissions,
                 CurrentScope::GrantDiagnosis.verdict_for(grant(role("Empty"), @report))
  end

  test "a role whose keys are all absent from the routed catalog can never match" do
    r = role("Stale")
    r.role_permissions.create!(permission_key: "ghosts#haunt")

    assert_equal :unrouted_permissions, CurrentScope::GrantDiagnosis.verdict_for(grant(r, @report))
  end

  test "one routed key is enough for no verdict" do
    assert_nil CurrentScope::GrantDiagnosis.verdict_for(
      grant(role("Real", "reports#approve"), @report))
  end

  test "the injected break-glass key alone is NOT enough — routed?, not include?" do
    # The catalog injects the bypass key onto any row routing an SoD action, so
    # `include?` is true for a key nothing routes. This builds that condition
    # rather than skipping when the default config lacks it — a skipped pin is
    # not a pin, and this is the only thing holding mutation 1.
    with_injected_bypass_key do
      bypass = CurrentScope.catalog.keys.find { |k| k.end_with?("#bypass_sod") }

      refute_nil bypass, "precondition: an SoD action should inject a bypass key"
      assert CurrentScope.catalog.include?(bypass), "precondition: it IS in the catalog"
      refute CurrentScope.catalog.routed?(bypass), "precondition: but nothing routes it"

      r = CurrentScope::Role.create!(name: "Bypass-#{rand(10**9)}")
      r.role_permissions.create!(permission_key: bypass)

      assert_equal :unrouted_permissions,
                   CurrentScope::GrantDiagnosis.verdict_for(grant(r, @report)),
                   "a role holding only the injected key can never be gated"
    end
  end

  # Injection needs BOTH knobs: the catalog only injects a bypass key when
  # allow_sod_bypass is on AND an SoD action is routed (permission_catalog.rb).
  def with_injected_bypass_key
    prev_actions = CurrentScope.config.sod_actions
    prev_bypass = CurrentScope.config.allow_sod_bypass
    CurrentScope.config.sod_actions = %w[approve]
    CurrentScope.config.allow_sod_bypass = true
    CurrentScope.reset_catalog!
    yield
  ensure
    CurrentScope.config.sod_actions = prev_actions
    CurrentScope.config.allow_sod_bypass = prev_bypass
    CurrentScope.reset_catalog!
  end

  # --- R4: full_access is never flagged, by either rule ---

  test "a full_access role is never flagged, even with zero ticked keys" do
    g = grant(role("Owner", full_access: true), @report)

    assert_nil CurrentScope::GrantDiagnosis.verdict_for(g)
    refute CurrentScope::GrantDiagnosis.type_untargeted?(g)
  end

  # --- R2: the advisory ---

  test "the advisory fires when no ticked key targets the grant's type" do
    assert CurrentScope::GrantDiagnosis.type_untargeted?(
      grant(role("Lead", "reports#approve"), @project)),
      "a Report-only role granted on a Project targets nothing of that type"
  end

  test "the advisory is silent when a ticked key targets the type" do
    refute CurrentScope::GrantDiagnosis.type_untargeted?(
      grant(role("Reader", "reports#approve"), @report))
  end

  test "a namespaced controller still targets its type" do
    refute CurrentScope::GrantDiagnosis.type_untargeted?(
      grant(role("Admin", "admin/reports#approve"), @report)),
      "admin/reports handles Reports — the last path segment is what matches"
  end

  # --- The false-positive pin. This is the test that matters most. ---

  test "a CUSTOM-NAMED controller for the same type is NOT flagged" do
    key = CurrentScope.catalog.keys.find { |k| k.start_with?("nested_reports#") }
    skip "dummy has no nested_reports route" if key.nil?

    refute CurrentScope::GrantDiagnosis.type_untargeted?(grant(role("Nested", key), @report)),
           "nested_reports gates Report records; flagging it would tell an operator " \
           "to remove a working grant, which is worse than saying nothing"
  end

  # --- KTD-2: the verdict wins ---

  test "the advisory stays silent when the verdict already speaks" do
    g = grant(role("Empty"), @project)

    assert_equal :no_permissions, CurrentScope::GrantDiagnosis.verdict_for(g)
    refute CurrentScope::GrantDiagnosis.type_untargeted?(g),
           "one grant must not produce two findings, the weaker restating the stronger"
  end

  # --- R8: degrade, never raise ---

  test "an unresolvable resource class yields no verdict and no advisory, without raising" do
    g = grant(role("Reader", "reports#approve"), @report)
    g.update_column(:resource_type, "GoneAway")

    assert_nothing_raised do
      assert_nil CurrentScope::GrantDiagnosis.verdict_for(g.reload)
      refute CurrentScope::GrantDiagnosis.type_untargeted?(g)
    end
  end
end
