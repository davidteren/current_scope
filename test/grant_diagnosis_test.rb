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

  test "the injected break-glass key alone is LIVE, not dead" do
    # The catalog injects the bypass key onto any row routing an SoD action.
    # It is NOT routed, but it IS live on that row, so "can this ever open
    # anything" must answer yes.
    with_injected_bypass_key do
      bypass = "reports#bypass_sod"

      refute_nil bypass, "precondition: an SoD action should inject a bypass key"
      assert CurrentScope.catalog.include?(bypass), "precondition: it IS in the catalog"
      refute CurrentScope.catalog.routed?(bypass), "precondition: but nothing routes it"

      r = CurrentScope::Role.create!(name: "Bypass-#{rand(10**9)}")
      r.role_permissions.create!(permission_key: bypass)

      assert_nil CurrentScope::GrantDiagnosis.verdict_for(grant(r, @report)),
                 "the INJECTED bypass key is live on its record — marking a role " \
                 "that holds only it dead would tell an operator to remove live, " \
                 "security-sensitive authority (found on PR #137)"
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

  test "an injected bypass key for ANOTHER type does not keep a grant alive" do
    # The exemption is row-local: the catalog injects the key per controller, so
    # claims#bypass_sod cannot lift anything on a Report. (cubic, PR #137)
    with_injected_bypass_key do
      r = CurrentScope::Role.create!(name: "Other-#{rand(10**9)}")
      r.role_permissions.create!(permission_key: "claims#bypass_sod")

      assert_equal :unrouted_permissions,
                   CurrentScope::GrantDiagnosis.verdict_for(grant(r, @report))
    end
  end

  # --- R4: full_access is never flagged, by either rule ---

  test "a full_access role is never flagged, even with zero ticked keys" do
    g = grant(role("Owner", full_access: true), @report)

    assert_nil CurrentScope::GrantDiagnosis.verdict_for(g)
    refute CurrentScope::GrantDiagnosis.type_untargeted?(g)
  end

  # --- R2: the advisory ---

  test "the advisory fires when no ticked key targets the grant's type" do
    # Folder deliberately, NOT Project: since #108 the dummy's Report declares
    # `current_scope_parent :project`, so a Report-keyed role granted on a
    # Project is a WORKING parent-chain grant. Nothing declares Folder as a
    # parent, so nothing reaches it.
    assert CurrentScope::GrantDiagnosis.type_untargeted?(
      grant(role("Lead", "reports#approve"), Folder.create!(name: "F"))),
      "a Report-only role granted on a Folder targets nothing of that type"
  end

  test "a working PARENT-CHAIN grant is NOT flagged — the #108 headline example" do
    # "Lead of Project 7 approves Project 7's reports": the role ticks only
    # reports#approve and the grant is on a Project, and it WORKS because Report
    # declares current_scope_parent :project. Flagging it would send an operator
    # to a hook that is already correct.
    g = grant(role("Lead", "reports#approve"), @project)

    assert_equal [ true, nil ],
                 CurrentScope::Resolver.new.decide(
                   subject: @user, permission: "reports#approve",
                   record: Report.create!(title: "child", project: @project, requested_by: @user)),
                 "precondition: the chain grant really does work"
    refute CurrentScope::GrantDiagnosis.type_untargeted?(g),
           "a grant the resolver honours must never be badged as unreachable"
  end

  test "an orphaned grant (#90 inert) gets no diagnosis — its record is gone, and that is a different fix" do
    g = grant(role("Empty"), @report)
    @report.destroy
    g.reload

    assert g.orphaned_resource?, "precondition: this is #90's state"
    assert_nil CurrentScope::GrantDiagnosis.verdict_for(g)
    refute CurrentScope::GrantDiagnosis.type_untargeted?(g)
  end

  test "a resolution failure degrades to no verdict rather than raising" do
    # The R8 pin. The previous version of this test only set an unresolvable
    # resource_type, which safe_constantize handles WITHOUT raising — so the
    # rescue clauses were never reached and deleting them broke nothing.
    g = grant(role("Reader", "reports#approve"), @report)

    catalog = CurrentScope.catalog
    catalog.define_singleton_method(:routed?) { |_key| raise ActiveRecord::StatementInvalid, "boom" }

    begin
      assert_nothing_raised do
        assert_nil CurrentScope::GrantDiagnosis.verdict_for(g)
        refute CurrentScope::GrantDiagnosis.type_untargeted?(g)
      end
    ensure
      CurrentScope.reset_catalog!
    end
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
    # refute_nil, not skip: this is the most load-bearing assertion in the file
    # and a route change must fail it loudly, not quietly disable it.
    refute_nil key, "the dummy must keep a nested_reports route for this pin to mean anything"

    refute CurrentScope::GrantDiagnosis.type_untargeted?(grant(role("Nested", key), @report)),
           "nested_reports gates Report records; flagging it would tell an operator " \
           "to remove a working grant, which is worse than saying nothing"
  end

  # NOT PINNED, deliberately, and both are P1 false-positive fixes:
  #
  #   STI subclass-named controller — the dummy routes only documents#*, so the
  #   shape (grant stored as "Document", key "invoices#show") cannot be built
  #   without adding a route to the dummy.
  #   Lazy-loaded models — clearing ParentChain.declared_names does not
  #   reproduce it, because the classes stay loaded; only a cold dev boot does.
  #
  # Stated rather than faked. See the PR body.

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
