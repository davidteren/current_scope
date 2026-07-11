require "test_helper"

# The read-only "who can do what" roster (U13). Unlike the engine's management
# UI (full-access gated → 403 for most personas), this surface is visible to
# EVERY acted-as persona, including the role-less Visitor — so the authorization
# model stays legible even to a subject locked out of the management UI. The
# mutating controls link INTO the gated engine UI and render only for a
# full-access viewer.
class UsersSurfaceTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(email_address: "owner-cs@example.com", password: "password")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))

    @preparer = users(:preparer)
    @approver = users(:approver)
    @scoped   = users(:scoped_user)
    @alpha    = expense_claims(:alpha) # submitted by @preparer — no SoD conflict for @approver

    base = %w[expense_claims#index expense_claims#show expense_claims#new expense_claims#create]
    CurrentScope::Role.create!(name: "Expenses Preparer").update!(permission_keys: base)
    @approver_role = CurrentScope::Role.create!(name: "Expenses Approver")
    @approver_role.update!(permission_keys: base + %w[expense_claims#approve])
    CurrentScope::RoleAssignment.create!(subject: @preparer, role: CurrentScope::Role.find_by!(name: "Expenses Preparer"))
    CurrentScope::RoleAssignment.create!(subject: @approver, role: @approver_role)

    lister = CurrentScope::Role.create!(name: "Expenses Lister")
    lister.update!(permission_keys: %w[expense_claims#index])
    viewer = CurrentScope::Role.create!(name: "Expenses Viewer")
    viewer.update!(permission_keys: %w[expense_claims#show])
    CurrentScope::RoleAssignment.create!(subject: @scoped, role: lister)
    CurrentScope::ScopedRoleAssignment.create!(subject: @scoped, role: viewer, resource: @alpha)
  end

  # Literal paths: after a request into the mounted engine the integration
  # session keeps its SCRIPT_NAME, which would skew the url helpers.
  def act_as(user)          = post "/act_as", params: { id: user.id }
  def sign_in_via_form(user) = post "/session", params: { email_address: user.email_address, password: "password" }
  def row(user)              = "#" + ActionView::RecordIdentifier.dom_id(user)

  test "the surface renders for the Visitor and for a non-full-access acted-as persona" do
    get "/"                       # anonymous → auto-signed-in as the role-less Visitor
    get "/users"
    assert_response :success      # roleless Visitor still SEES the model — not 403

    act_as(@preparer)             # a non-full-access persona
    get "/users"
    assert_response :success      # still 200, not the engine UI's 403
  end

  test "engine management links are hidden below full access and shown for a full-access owner" do
    get "/"                       # Visitor: no role, not full access
    get "/users"
    assert_response :success
    assert_select "a[href=?]", "/current_scope/roles", count: 0
    assert_select "a[href=?]", "/current_scope/scoped_role_assignments/new", count: 0
    assert_select "a[href=?]", "/current_scope/events", count: 0

    sign_in_via_form(@owner)      # full access
    get "/users"
    assert_response :success
    assert_select "a[href=?]", "/current_scope/roles", count: 1
    assert_select "a[href=?]", "/current_scope/scoped_role_assignments/new", count: 1
    assert_select "a[href=?]", "/current_scope/events", count: 1
  end

  test "chips reflect a user's org-wide role and their scoped roles" do
    get "/"
    get "/users"
    assert_response :success
    assert_select row(@scoped) do
      assert_select ".cs-chip", text: "Expenses Lister"                                    # org-wide role
      assert_select ".cs-chip", text: /Expenses Viewer of Expense claim ##{@alpha.id}/      # scoped role
    end
  end

  # The live-grid beat: flip a grant in the engine grid, and the acted-as
  # persona's behavior changes on the next load — no cache to clear, since every
  # check is per-request.
  test "removing expense_claims#approve from the approver role removes the Approve control on next load" do
    approve_form = "/expense_claims/#{@alpha.id}/approve"

    # BEFORE: the approver can approve the preparer's claim.
    sign_in_via_form(@approver)
    get "/expense_claims/#{@alpha.id}"
    assert_response :success
    assert_select "form[action=?]", approve_form, count: 1

    # The owner unticks expense_claims#approve on the Expenses Approver role via
    # the gated engine grid — authorization as data.
    sign_in_via_form(@owner)
    patch "/current_scope/roles/#{@approver_role.id}",
      params: { role: { name: @approver_role.name,
                        permission_keys: %w[expense_claims#index expense_claims#show expense_claims#new expense_claims#create] } }
    assert_response :redirect
    assert_not @approver_role.reload.grants?("expense_claims#approve")

    # AFTER: the same approver, same claim — the control is gone and a forced
    # POST is refused. The change took effect on the very next request.
    sign_in_via_form(@approver)
    get "/expense_claims/#{@alpha.id}"
    assert_response :success
    assert_select "form[action=?]", approve_form, count: 0

    post approve_form
    assert_response :forbidden
    assert_not @alpha.reload.approved?
  end

  test "a user identity containing markup renders escaped" do
    User.create!(email_address: "<b>x</b>@example.com", password: "password")
    get "/"
    get "/users"
    assert_response :success
    assert_includes @response.body, ERB::Util.html_escape("<b>x</b>@example.com")
    assert_not_includes @response.body, "<b>x</b>@example.com"
  end
end
