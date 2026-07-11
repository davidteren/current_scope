# The gallery's proof, run identically against every SoD domain. A including
# class supplies only `prefix` (e.g. "pay_runs"), `param_key`, `markup_field`,
# and `valid_attrs`; the fixtures alpha/beta/gamma follow the same shape in
# every domain:
#
#   alpha — prepared by @preparer  (approver approves it; the scoped grant target)
#   beta  — prepared by @approver  (the SoD self-approve veto case)
#   gamma — prepared by @preparer  (scoped persona must NOT see it; carries markup)
module ApprovalDomainFlow
  extend ActiveSupport::Concern

  included do
    setup do
      @preparer  = users(:preparer)
      @approver  = users(:approver)
      @scoped    = users(:scoped_user)
      @bystander = users(:bystander)

      @alpha = fixture_record(:alpha)
      @beta  = fixture_record(:beta)
      @gamma = fixture_record(:gamma)

      base = %W[#{prefix}#index #{prefix}#show #{prefix}#new #{prefix}#create]
      preparer_role = CurrentScope::Role.create!(name: "#{prefix} preparer")
      preparer_role.update!(permission_keys: base)
      approver_role = CurrentScope::Role.create!(name: "#{prefix} approver")
      approver_role.update!(permission_keys: base + %W[#{prefix}#approve])
      lister_role = CurrentScope::Role.create!(name: "#{prefix} lister")
      lister_role.update!(permission_keys: %W[#{prefix}#index])
      scoped_role = CurrentScope::Role.create!(name: "#{prefix} scoped")
      scoped_role.update!(permission_keys: %W[#{prefix}#show #{prefix}#approve])

      CurrentScope::RoleAssignment.create!(subject: @preparer, role: preparer_role)
      CurrentScope::RoleAssignment.create!(subject: @approver, role: approver_role)
      CurrentScope::RoleAssignment.create!(subject: @scoped, role: lister_role)
      CurrentScope::ScopedRoleAssignment.create!(subject: @scoped, role: scoped_role, resource: @alpha)
      # @bystander gets nothing.
    end

    test "preparer creates a record but is default-denied on approving their own" do
      sign_in_via_form(@preparer)

      assert_difference "#{model.name}.count" do
        post index_path, params: { param_key => valid_attrs }
      end
      assert_equal @preparer, model.last.current_scope_initiator

      # The approve control is absent...
      get record_path(@gamma) # prepared by @preparer
      assert_response :success
      assert_select "form[action=?]", approve_path(@gamma), count: 0

      # ...and a crafted POST is refused.
      post approve_path(@gamma)
      assert_response :forbidden
      assert_not @gamma.reload.approved?
    end

    test "SoD veto: an approver cannot approve a record they initiated" do
      sign_in_via_form(@approver)

      get record_path(@beta) # initiated by @approver, who HOLDS approve
      assert_response :success
      assert_select "form[action=?]", approve_path(@beta), count: 0

      post approve_path(@beta)
      assert_response :forbidden
      assert_not @beta.reload.approved?
    end

    test "an approver approves another initiator's record" do
      sign_in_via_form(@approver)

      post approve_path(@alpha) # initiated by @preparer
      assert_redirected_to record_path(@alpha)
      assert @alpha.reload.approved?
      assert_equal @approver, @alpha.approved_by
    end

    test "a scoped persona approves EXACTLY the one granted record, nothing else" do
      sign_in_via_form(@scoped)

      post approve_path(@alpha)
      assert_redirected_to record_path(@alpha)
      assert @alpha.reload.approved?

      post approve_path(@beta)
      assert_response :forbidden
      post approve_path(@gamma)
      assert_response :forbidden
    end

    test "scope_for index: scoped persona sees only their record; approver sees all" do
      sign_in_via_form(@scoped)
      get index_path
      assert_response :success
      assert_select "##{dom_id(@alpha)}"
      assert_select "##{dom_id(@beta)}", count: 0
      assert_select "##{dom_id(@gamma)}", count: 0

      sign_in_via_form(@approver)
      get index_path
      assert_select "##{dom_id(@alpha)}"
      assert_select "##{dom_id(@beta)}"
      assert_select "##{dom_id(@gamma)}"
    end

    test "a bystander with no grants is default-denied" do
      sign_in_via_form(@bystander)

      get index_path
      assert_response :forbidden
      get record_path(@alpha)
      assert_response :forbidden
    end

    test "the domain's controller#actions appear automatically in the permission grid" do
      owner = User.create!(email_address: "grid-owner@example.com", password: "password")
      CurrentScope::RoleAssignment.create!(
        subject: owner, role: CurrentScope::Role.create!(name: "#{prefix} grid owner", full_access: true))
      role = CurrentScope::Role.create!(name: "#{prefix} editable")

      sign_in_via_form(owner)
      get current_scope.edit_role_path(role)
      assert_response :success
      assert_select "input[type=checkbox][value=?]", "#{prefix}#approve"
      assert_select "input[type=checkbox][value=?]", "#{prefix}#index"
    end

    test "the domain switcher marks aria-current on the active domain" do
      sign_in_via_form(@approver)
      get index_path
      assert_select "a[href=?][aria-current='page']", index_path
    end

    test "a visitor-authored value containing markup renders ESCAPED in the index" do
      sign_in_via_form(@approver) # sees all rows, including gamma
      get index_path
      assert_response :success

      raw = @gamma.public_send(markup_field)
      assert_includes @response.body, ERB::Util.html_escape(raw)
      assert_not_includes @response.body, raw
    end
  end

  private
    def sign_in_via_form(user)
      # Literal path: after a request into the mounted engine the integration
      # session keeps its SCRIPT_NAME, which would skew session_url.
      post "/session", params: { email_address: user.email_address, password: "password" }
    end

    def model = prefix.classify.constantize
    def dom_id(record) = ActionView::RecordIdentifier.dom_id(record)
    def fixture_record(name) = public_send(prefix, name)
    def index_path = public_send("#{prefix}_path")
    def record_path(record) = public_send("#{prefix.singularize}_path", record)
    def approve_path(record) = public_send("approve_#{prefix.singularize}_path", record)
end
