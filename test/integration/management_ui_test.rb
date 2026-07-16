require "test_helper"

class ManagementUiTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    @member = User.create!(name: "Member")
    @owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @member_role = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    CurrentScope::RoleAssignment.create!(subject: @member, role: @member_role)
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "the management UI is closed to anonymous and non-full-access subjects" do
    get current_scope.roles_url
    assert_response :forbidden

    get current_scope.roles_url, headers: as(@member)
    assert_response :forbidden
  end

  # The engine's front door was the one denial in the gem with no reason header
  # and a 0-byte body — it rendered its own `head :forbidden` instead of routing
  # through the shared AccessDenied path every other denial uses. "Why can't I
  # open the management UI?" is the first question an admin asks, and the answer
  # was nothing at all. (#23)
  test "the engine 403 carries the reason header, like every other denial" do
    get current_scope.roles_url, headers: as(@member)

    assert_response :forbidden
    assert_equal "not_full_access", response.headers["X-Current-Scope-Reason"]
  end

  test "the engine 403 says why, rather than returning a blank page" do
    get current_scope.roles_url, headers: as(@member)

    assert_response :forbidden
    assert_not_empty response.body, "a bodyless 403 tells the admin nothing"
    assert_match(/full-access/i, response.body)
  end

  test "an anonymous request to the engine gets the same reason and page" do
    get current_scope.roles_url

    assert_response :forbidden
    assert_equal "not_full_access", response.headers["X-Current-Scope-Reason"]
    assert_not_empty response.body
  end

  # The explanation page answers ONE question, so it must only be shown to
  # someone asking it. A non-HTML client asked for something else entirely.
  test "a non-HTML request gets the bodyless 403, not an HTML body" do
    get current_scope.roles_url, headers: as(@member).merge("Accept" => "application/json")

    assert_response :forbidden
    assert_equal "not_full_access", response.headers["X-Current-Scope-Reason"], "the reason is the signal here"
    assert_empty response.body, "an HTML page under a content type nobody asked for is not an answer"
  end

  # R1: presentation changed, not the gate. Every engine surface stays closed to
  # exactly who it closed to before.
  test "who is denied does not change" do
    [ current_scope.roles_url, current_scope.subjects_url, current_scope.events_url ].each do |url|
      get url, headers: as(@member)
      assert_response :forbidden, "#{url} must stay closed to a non-full-access subject"

      get url, headers: as(@owner)
      assert_response :success, "#{url} must stay open to a full-access subject"
    end
  end

  test "a full-access subject can view and edit roles" do
    get current_scope.roles_url, headers: as(@owner)
    assert_response :success

    get current_scope.edit_role_url(@member_role), headers: as(@owner)
    assert_response :success
    # The grid folds index+show into the "read" CRUD group; its checkbox carries
    # the controller:group token.
    assert_match "reports:read", response.body
  end

  test "saving the grid replaces permissions" do
    patch current_scope.role_url(@member_role), headers: as(@owner), params: {
      role: { name: "Member", full_access: "0",
              permission_keys: [ "", "reports#index" ] } # "" is the grid's hidden padding
    }
    assert_redirected_to current_scope.roles_url

    assert_equal [ "reports#index" ], @member_role.reload.permission_keys
  end

  # A key outside the catalog cannot come from the grid — cells are built from
  # routed actions only. So it means a hand-crafted request or a caller that
  # believes in a permission the app doesn't route, and either way the answer is
  # to say so, not to drop it and redirect as though it had been granted.
  test "a permission key outside the catalog is rejected loudly, not dropped" do
    patch current_scope.role_url(@member_role), headers: as(@owner), params: {
      role: { name: "Member", full_access: "0",
              permission_keys: [ "", "reports#index", "bogus#nope" ] }
    }
    assert_response :unprocessable_entity
    assert_match "bogus#nope", response.body

    assert_empty @member_role.reload.permission_keys, "a rejected save must persist nothing"
  end

  test "setting and clearing a subject's org-wide role" do
    other = User.create!(name: "Other")

    post current_scope.role_assignment_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: @member_role.id }
    assert_equal @member_role, CurrentScope::RoleAssignment.find_by(subject: other).role

    post current_scope.role_assignment_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: "" }
    assert_nil CurrentScope::RoleAssignment.find_by(subject: other)
  end

  test "granting and revoking a scoped role" do
    report = Report.create!(title: "Q3", requested_by: @owner)

    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      subject_gid: @member.to_gid.to_s, resource_gid: report.to_gid.to_s,
      role_id: @member_role.id
    }
    sra = CurrentScope::ScopedRoleAssignment.find_by(subject: @member)
    assert_equal report, sra.resource

    delete current_scope.scoped_role_assignment_url(sra), headers: as(@owner)
    assert_nil CurrentScope::ScopedRoleAssignment.find_by(subject: @member)
  end

  test "refuses to delete the last full-access role" do
    delete current_scope.role_url(@owner_role), headers: as(@owner)
    assert_redirected_to current_scope.roles_url
    assert CurrentScope::Role.exists?(@owner_role.id)

    CurrentScope::Role.create!(name: "SecondOwner", full_access: true)
    delete current_scope.role_url(@owner_role), headers: as(@owner)
    assert_not CurrentScope::Role.exists?(@owner_role.id)
  end

  test "subjects page renders role chips" do
    get current_scope.subjects_url, headers: as(@owner)
    assert_response :success
    assert_match "Owner", response.body
  end

  # The page keys its role lookups by what the polymorphic association STORES —
  # the base_class name. An STI subject (Invoice < Document) is saved as
  # "Document"; keying rows on subject.class.name would miss the lookup and
  # show "— none —" for a subject the resolver happily authorizes.
  test "an STI subject's org-wide and scoped roles render, not '— none —'" do
    original = CurrentScope.config.subject_class
    CurrentScope.config.subject_class = "Document"

    invoice = Invoice.create!(title: "INV-1")
    folder = Folder.create!(name: "Q3")
    CurrentScope::RoleAssignment.create!(subject: invoice, role: @member_role)
    CurrentScope::ScopedRoleAssignment.create!(subject: invoice, role: @member_role, resource: folder)

    get current_scope.subjects_url, headers: as(@owner)
    assert_response :success
    assert_select "select[name=role_id] option[selected]", text: "Member",
                  count: 1
    assert_select "span.cs-chip-label", text: /Member of/, count: 1
  ensure
    CurrentScope.config.subject_class = original
  end
end
