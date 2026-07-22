require "test_helper"

# The read-only-while-impersonating mutation gate, exercised end to end. It is
# a SEPARATE before_action from the permission check, so it must survive
# skip_before_action :current_scope_check! — including on the engine's own
# management UI. config.actor_method / allow_mutations_while_impersonating are
# global, so each test restores them.
class ImpersonationGateTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "Admin")     # the REAL actor
    @member = User.create!(name: "Member")   # the impersonated effective subject
    @report = Report.create!(title: "Q3", requested_by: @admin)

    @original_actor_method = CurrentScope.config.actor_method
    @original_allow = CurrentScope.config.allow_mutations_while_impersonating
    CurrentScope.config.actor_method = :true_user
  end

  teardown do
    CurrentScope.config.actor_method = @original_actor_method
    CurrentScope.config.allow_mutations_while_impersonating = @original_allow
  end

  def assign(user, role)
    CurrentScope::RoleAssignment.create!(subject: user, role: role)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  # Impersonating: real actor (admin) stands behind a different subject (member).
  def acting_as(subject:, actor:)
    { "X-User-Id" => subject.id.to_s, "X-Actor-Id" => actor.id.to_s }
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "a mutation while impersonating is denied by default, with reason impersonation_gate" do
    assign(@member, role("Owner", full_access: true))
    post approve_report_url(@report), headers: acting_as(subject: @member, actor: @admin)
    assert_response :forbidden
    assert_equal "impersonation_gate", response.headers["X-Current-Scope-Reason"]
  end

  # #39 — impersonation gate is verb-based; #record stays nil, #subject is set.
  test "AccessDenied on the impersonation gate has nil record and the effective subject" do
    assign(@member, role("Owner", full_access: true))
    captured = nil
    ReportsController.class_eval do
      define_method(:current_scope_denied) do |exception = nil|
        captured = exception
        reason = exception.respond_to?(:reason) ? exception.reason : nil
        response.headers["X-Current-Scope-Reason"] = reason.to_s if reason
        head :forbidden
      end
    end

    post approve_report_url(@report), headers: acting_as(subject: @member, actor: @admin)
    assert_response :forbidden
    assert_kind_of CurrentScope::AccessDenied, captured
    assert_equal "reports#approve", captured.permission
    assert_equal :impersonation_gate, captured.reason
    assert_nil captured.record, "impersonation gate loads no record"
    assert_equal @member, captured.subject
  ensure
    if ReportsController.instance_methods(false).include?(:current_scope_denied)
      ReportsController.class_eval { remove_method :current_scope_denied }
    end
  end

  test "an impersonation-gate denial logs permission and reason" do
    assign(@member, role("Owner", full_access: true))
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |l| l.level = Logger::INFO }

    post approve_report_url(@report), headers: acting_as(subject: @member, actor: @admin)
    assert_response :forbidden
    assert_match(
      /\[CurrentScope\] denied reports#approve \(impersonation_gate\) → 403/,
      io.string
    )
  ensure
    Rails.logger = original
  end

  test "a GET while impersonating is allowed (reads stay open)" do
    assign(@member, role("Owner", full_access: true))
    get reports_url, headers: acting_as(subject: @member, actor: @admin)
    assert_response :success
  end

  test "the gate is inert when not impersonating" do
    assign(@member, role("Owner", full_access: true))
    post approve_report_url(@report), headers: as(@member)
    assert_response :success
  end

  test "config.allow_mutations_while_impersonating opens the gate" do
    CurrentScope.config.allow_mutations_while_impersonating = true
    assign(@member, role("Owner", full_access: true))
    # Initiated by a third party so the SoD :either veto (now observable once
    # mutations are allowed) does not fire — this isolates the gate.
    neutral = Report.create!(title: "Q4", requested_by: User.create!(name: "Third"))
    post approve_report_url(neutral), headers: acting_as(subject: @member, actor: @admin)
    assert_response :success
  end

  test "full_access does not bypass the gate" do
    assign(@member, role("Owner", full_access: true))
    post approve_report_url(@report), headers: acting_as(subject: @member, actor: @admin)
    assert_response :forbidden
  end

  test "the engine's own management UI mutations are refused while impersonating" do
    assign(@member, role("Owner", full_access: true))
    member_role = CurrentScope::Role.create!(name: "Member")

    patch current_scope.role_url(member_role),
          headers: acting_as(subject: @member, actor: @admin),
          params: { role: { name: "Member", full_access: "0", permission_keys: [ "reports#index" ] } }

    assert_response :forbidden
    assert_equal "impersonation_gate", response.headers["X-Current-Scope-Reason"]
    assert_empty member_role.reload.permission_keys

    # The engine renders an explanation page for its OWN denial (#23), and this
    # is not it. This subject HAS full access — they are refused for being
    # impersonated. Telling them to get a full-access role would be a
    # confidently wrong answer, which is worse than saying nothing.
    assert_no_match(/full-access role/, response.body,
      "the impersonation gate must not borrow the full-access explanation")
    assert_empty response.body, "a reason this page doesn't answer falls back to the bodyless 403"
  end

  test "the management UI is still viewable while impersonating (read-only)" do
    assign(@member, role("Owner", full_access: true))
    get current_scope.roles_url, headers: acting_as(subject: @member, actor: @admin)
    assert_response :success
  end

  test "an endpoint that skips the mutation guard can mutate while impersonating" do
    post writes_unguarded_url, headers: acting_as(subject: @member, actor: @admin)
    assert_response :success
  end

  test "skipping the permission gate does NOT skip the impersonation gate" do
    # writes#guarded skips current_scope_check! but keeps the mutation guard.
    post writes_guarded_url, headers: acting_as(subject: @member, actor: @admin)
    assert_response :forbidden
    assert_equal "impersonation_gate", response.headers["X-Current-Scope-Reason"]

    # ...and it is a normal 200 when nobody is impersonating.
    post writes_guarded_url, headers: as(@member)
    assert_response :success
  end
end
