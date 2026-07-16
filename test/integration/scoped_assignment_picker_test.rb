require "test_helper"

# The guided scoped-role picker (Role → Subject → Resource type → Record) and
# the error paths that must degrade to a friendly flash instead of a 500.
class ScopedAssignmentPickerTest < ActionDispatch::IntegrationTest
  setup do
    Folder # autoload ⇒ self-registers as a Scopeable type
    @owner = User.create!(name: "Owner")
    @member = User.create!(name: "Member")
    @owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @member_role = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    CurrentScope::RoleAssignment.create!(subject: @member, role: @member_role)
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  # Swap CurrentScope.scopeable_resources for one test (Minitest 6 dropped
  # minitest/mock), matching the house style in audit_events_test.
  def with_scopeable_resources(list)
    original = CurrentScope.method(:scopeable_resources)
    CurrentScope.define_singleton_method(:scopeable_resources) { list }
    yield
  ensure
    CurrentScope.define_singleton_method(:scopeable_resources, original)
  end

  # --- happy path ----------------------------------------------------------

  test "the full cascade grants the role on the chosen record" do
    folder = Folder.create!(name: "Q3 Ledger")

    # GET the cascade with a type chosen: the record step renders server-side.
    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder"), headers: as(@owner)
    assert_response :success
    assert_select "select[name=resource_gid] option", text: "Q3 Ledger"

    # POST the completed picker.
    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      role_id: @member_role.id, subject_gid: @member.to_gid.to_s, resource_gid: folder.to_gid.to_s
    }
    assert_redirected_to current_scope.subjects_url

    sra = CurrentScope::ScopedRoleAssignment.find_by(subject: @member)
    assert_equal folder, sra.resource
    assert_equal @member_role, sra.role
  end

  test "the cascade serves the engine's JavaScript asset and marks controls for autosubmit" do
    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder"), headers: as(@owner)

    assert_select "script[src*=?]", "current_scope/application"
    assert_select "[data-current-scope-autosubmit]"
  end

  # --- upstream preservation ----------------------------------------------

  test "each step re-render preserves the upstream role, subject, and type" do
    folder = Folder.create!(name: "Payroll")

    get current_scope.new_scoped_role_assignment_url(
      role_id: @member_role.id, subject_gid: @member.to_gid.to_s,
      resource_type: "Folder", resource_gid: folder.to_gid.to_s
    ), headers: as(@owner)
    assert_response :success

    assert_select "select[name=role_id] option[selected][value=?]", @member_role.id.to_s
    assert_select "select[name=subject_gid] option[selected][value=?]", @member.to_gid.to_s
    assert_select "select[name=resource_type] option[selected][value=Folder]"
    assert_select "select[name=resource_gid] option[selected][value=?]", folder.to_gid.to_s
  end

  # --- record search (Ruby-side filter) -----------------------------------

  test "record search filters by label substring, case-insensitively" do
    25.times { |i| Folder.create!(name: "Ledger #{i}") }
    needle = Folder.create!(name: "Unique Vault")

    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder", q: "unique va"), headers: as(@owner)
    assert_response :success

    assert_select "input[name=q]" # many records ⇒ a search box appears
    assert_select "select[name=resource_gid] option", text: "Unique Vault"
    assert_select "select[name=resource_gid] option", text: "Ledger 0", count: 0
    assert_select "select[name=resource_gid] option[value=?]", needle.to_gid.to_s
  end

  test "a search with zero matches says so instead of claiming matches are shown" do
    25.times { |i| Folder.create!(name: "Ledger #{i}") }

    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder", q: "zzz-no-such"), headers: as(@owner)
    assert_response :success

    assert_match "No records match", response.body
    assert_no_match(/Showing up to \d+ matches/, response.body)
  end

  # The deep-linked record is prepended to the options so it stays selectable —
  # but it is not a search MATCH, and must not flip the hint back to
  # "Showing up to N matches" when the query itself found nothing.
  test "a zero-match search with a deep-linked record still says no match" do
    25.times { |i| Folder.create!(name: "Ledger #{i}") }
    pinned = Folder.create!(name: "Pinned Vault")

    get current_scope.new_scoped_role_assignment_url(
      resource_type: "Folder", q: "zzz-no-such", resource_gid: pinned.to_gid.to_s
    ), headers: as(@owner)
    assert_response :success

    assert_select "select[name=resource_gid] option[value=?]", pinned.to_gid.to_s # still selectable
    assert_match "No records match", response.body
    assert_no_match(/Showing up to \d+ matches/, response.body)
  end

  test "record search honors the display limit" do
    60.times { |i| Folder.create!(name: "Match #{i}") }

    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder", q: "match"), headers: as(@owner)
    assert_response :success

    rendered = css_select("select[name=resource_gid] option").map { |o| o["value"] }.count { |v| v.to_s.include?("gid://") }
    assert_operator rendered, :<=, CurrentScope::ScopedRoleAssignmentsController::DISPLAY_LIMIT
  end

  # --- empty states --------------------------------------------------------

  test "an empty scopeable registry renders developer copy naming the mixin" do
    with_scopeable_resources([]) do
      get current_scope.new_scoped_role_assignment_url, headers: as(@owner)
    end
    assert_response :success
    assert_match "CurrentScope::Scopeable", response.body
  end

  test "a resource type with zero records renders the zero-records copy" do
    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder"), headers: as(@owner)
    assert_response :success
    assert_select "select[name=resource_gid]", count: 0
    assert_match(/no folders/i, response.body)
  end

  # --- deep-link two-door --------------------------------------------------

  test "a deep-link resource_gid prefills the type and record" do
    folder = Folder.create!(name: "Linked Folder")

    get current_scope.new_scoped_role_assignment_url(resource_gid: folder.to_gid.to_s), headers: as(@owner)
    assert_response :success

    assert_select "select[name=resource_type] option[selected][value=Folder]"
    assert_select "select[name=resource_gid] option[selected][value=?]", folder.to_gid.to_s
  end

  # --- error-path hardening (no 500s) --------------------------------------

  test "a duplicate grant is rescued to a flash, not a 500" do
    folder = Folder.create!(name: "Books")
    CurrentScope::ScopedRoleAssignment.create!(subject: @member, resource: folder, role: @member_role)

    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      role_id: @member_role.id, subject_gid: @member.to_gid.to_s, resource_gid: folder.to_gid.to_s
    }
    assert_response :redirect
    # A duplicate is now handled gracefully as a notice (bulk-friendly), not a 500.
    assert flash[:notice].present?
    assert_equal 1, CurrentScope::ScopedRoleAssignment.where(subject: @member).count
  end

  test "a concurrent duplicate (RecordNotUnique) is rescued, not a 500" do
    folder = Folder.create!(name: "Books")
    original = CurrentScope::ScopedRoleAssignment.method(:create!)
    CurrentScope::ScopedRoleAssignment.define_singleton_method(:create!) do |*, **|
      raise ActiveRecord::RecordNotUnique, "duplicate key"
    end

    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      role_id: @member_role.id, subject_gid: @member.to_gid.to_s, resource_gid: folder.to_gid.to_s
    }
    assert_response :redirect
    # Graceful, not a 500 — a flash is set either way (notice when swallowed as
    # already-granted, alert if surfaced).
    assert (flash[:notice] || flash[:alert]).present?
  ensure
    CurrentScope::ScopedRoleAssignment.define_singleton_method(:create!, original)
  end

  test "revoking an already-revoked assignment is rescued to a notice, not a 500" do
    delete current_scope.scoped_role_assignment_url(id: 999_999), headers: as(@owner)
    assert_response :redirect
    assert flash[:notice].present?
  end

  test "a dead deep-link GID is rescued to an alert, not a 500" do
    folder = Folder.create!(name: "Doomed")
    dead_gid = folder.to_gid.to_s
    folder.destroy!

    get current_scope.new_scoped_role_assignment_url(resource_gid: dead_gid), headers: as(@owner)
    assert_response :success
    assert_select ".cs-flash--alert"
  end

  # --- escaping ------------------------------------------------------------

  test "a record label containing markup renders escaped in the picker" do
    Folder.create!(name: "<script>alert('x')</script>")

    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder"), headers: as(@owner)
    assert_response :success
    assert_not_includes response.body, "<script>alert('x')</script>"
    assert_includes response.body, "&lt;script&gt;"
  end

  # --- CSRF: the grant posts its token in the body, never a GET URL --------

  test "the GET cascade form carries no CSRF token; the grant is a separate POST" do
    folder = Folder.create!(name: "Q3 Ledger")

    get current_scope.new_scoped_role_assignment_url(
      role_id: @member_role.id, subject_gid: @member.to_gid.to_s,
      resource_type: "Folder", resource_gid: folder.to_gid.to_s
    ), headers: as(@owner)
    assert_response :success

    # A CSRF token in a GET form leaks into the URL (server logs, browser
    # history, Referer). The idempotent cascade GET must carry no token.
    assert_select "form[method=get] input[name=authenticity_token]", count: 0

    # The grant is a state change: a separate POST form to the create path, so
    # its CSRF token rides in the request body (Rails injects it when forgery
    # protection is on; the test env keeps it off). Nothing about the grant
    # touches a URL query string.
    assert_select "form[method=post][action=?]", current_scope.scoped_role_assignments_path

    # And that POST still grants the completed selection.
    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      role_id: @member_role.id, subject_gid: @member.to_gid.to_s, resource_gid: folder.to_gid.to_s
    }
    assert_redirected_to current_scope.subjects_url
    assert CurrentScope::ScopedRoleAssignment.exists?(subject: @member, resource: folder, role: @member_role)
  end

  # --- progressive enhancement --------------------------------------------

  test "the cascade works without JS: a plain GET renders the next step" do
    Folder.create!(name: "No-JS Folder")

    get current_scope.new_scoped_role_assignment_url(resource_type: "Folder"), headers: as(@owner)
    assert_response :success
    # A visible submit button drives the cascade with no JavaScript at all.
    assert_select "input[type=submit]"
    assert_select "select[name=resource_gid] option", text: "No-JS Folder"
  end
end
