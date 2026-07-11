require "test_helper"

# End-to-end validation of the gem inside a real host app: real sign-in
# (Rails' built-in authentication), real routes, real views.
class AuthorizationFlowTest < ActionDispatch::IntegrationTest
  setup do
    @member = users(:one)
    @reviewer = users(:two)
    @report = reports(:one)   # requested by @member

    member_role = CurrentScope::Role.create!(name: "Member")
    member_role.update!(permission_keys: %w[projects#index projects#show reports#index reports#show reports#new reports#create])
    reviewer_role = CurrentScope::Role.create!(name: "Reviewer")
    reviewer_role.update!(permission_keys: member_role.permission_keys + %w[reports#approve])

    CurrentScope::RoleAssignment.create!(subject: @member, role: member_role)
    CurrentScope::RoleAssignment.create!(subject: @reviewer, role: reviewer_role)
  end

  def sign_in_via_form(user)
    # Literal path: after a request into the mounted engine, the integration
    # session keeps its SCRIPT_NAME, which would skew session_url.
    post "/session", params: { email_address: user.email_address, password: "password" }
  end

  test "an anonymous hit is auto-signed-in as the roleless Visitor (fail-closed, not a login redirect)" do
    get reports_url
    # U11: the public showcase auto-signs-in anonymous visitors as the roleless
    # Visitor instead of bouncing to login, so a gated page is fail-closed (403),
    # never a redirect. A Visitor session is created along the way.
    assert_response :forbidden
    assert cookies[:session_id].present?
  end

  test "a member can browse and create but not approve" do
    sign_in_via_form(@member)

    get reports_url
    assert_response :success

    assert_difference "Report.count" do
      post reports_url, params: { report: { title: "New", project_id: projects(:one).id } }
    end
    assert_equal @member, Report.last.requested_by

    post approve_report_url(reports(:two))
    assert_response :forbidden
  end

  test "a reviewer can approve someone else's report" do
    sign_in_via_form(@reviewer)

    post approve_report_url(@report)
    assert_redirected_to report_url(@report)
    assert @report.reload.approved?
    assert_equal @reviewer, @report.approved_by
  end

  test "SoD veto: a reviewer cannot approve a report they requested" do
    sign_in_via_form(@reviewer)

    post approve_report_url(reports(:two))
    assert_response :forbidden
    assert_not reports(:two).reload.approved?
  end

  test "the view hides what the gate forbids: member sees no approve button" do
    sign_in_via_form(@member)

    get report_url(reports(:two))
    assert_response :success
    assert_select "form[action=?]", approve_report_path(reports(:two)), count: 0

    sign_in_via_form(@reviewer)
    get report_url(@report)
    assert_select "form[action=?]", approve_report_path(@report), count: 1
  end

  test "the approve button is hidden from the requester (SoD in the view)" do
    sign_in_via_form(@reviewer)

    get report_url(reports(:two))   # requested by @reviewer
    assert_response :success
    assert_select "form[action=?]", approve_report_path(reports(:two)), count: 0
  end

  test "a scoped role opens exactly one record" do
    lister = CurrentScope::Role.create!(name: "Lister")
    lister.update!(permission_keys: %w[reports#index])
    viewer = CurrentScope::Role.create!(name: "Viewer")
    viewer.update!(permission_keys: %w[reports#show])

    scoped_user = User.create!(email_address: "scoped@example.com", password: "password")
    CurrentScope::RoleAssignment.create!(subject: scoped_user, role: lister)
    CurrentScope::ScopedRoleAssignment.create!(subject: scoped_user, role: viewer, resource: @report)

    sign_in_via_form(scoped_user)

    get report_url(@report)
    assert_response :success

    get report_url(reports(:two))
    assert_response :forbidden
  end

  test "the management UI requires full access" do
    sign_in_via_form(@reviewer)
    get current_scope.roles_url
    assert_response :forbidden

    owner = User.create!(email_address: "owner@example.com", password: "password")
    CurrentScope::RoleAssignment.create!(
      subject: owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))

    sign_in_via_form(owner)
    get current_scope.roles_url
    assert_response :success
  end
end
