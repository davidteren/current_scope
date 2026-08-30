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

  teardown do
    [ Folder, Document, Invoice, Receipt, SpecialInvoice ].each do |klass|
      next unless klass.instance_variable_defined?(:@current_scope_grantable_roles)

      klass.send(:remove_instance_variable, :@current_scope_grantable_roles)
    end
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

  # The real module, not a hand-rolled double: the picker and the model gate
  # share one predicate, and a double that answers only half of it would let this
  # test pass while the shipped code disagreed with itself (#183 review).
  def picky_type
    Class.new do
      include CurrentScope::GrantableRoles
      def self.name = "PickyThing"
      def self.model_name = ActiveModel::Name.new(self, nil, "PickyThing")
      self.current_scope_grantable_roles = [ "Owner" ]
    end
  end

  # #183 — the picker chooses the ROLE first, so the types are what gets
  # narrowed. The model validation is the gate; this only keeps the operator out
  # of a dead end, and says so rather than silently shortening the dropdown.
  test "a type that does not accept the chosen role is withheld, and the reason is shown" do
    picky = picky_type

    with_scopeable_resources([ Folder, picky ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id), headers: as(@owner)

      assert_response :success
      assert_select "option[value=?]", "Folder"
      assert_select "option[value=?]", "PickyThing", count: 0
      assert_match(/1 type not listed/, response.body)
      assert_match(/Member/, response.body, "and it names the role that was not accepted")
    end
  end

  # The two empties are different (#183 review). Sending an operator whose role
  # matched nothing to "add include CurrentScope::Scopeable" is advice that
  # cannot help them: the types ARE registered.
  test "when every type withholds the role, the page says so rather than blaming setup" do
    with_scopeable_resources([ picky_type ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id), headers: as(@owner)

      assert_response :success
      assert_match(/No resource type accepts/, response.body)
      assert_match(/Member/, response.body)
      assert_no_match(/No pickable resource types yet/, response.body)
    end
  end

  test "with nothing registered at all, the setup advice is still the right advice" do
    with_scopeable_resources([]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id), headers: as(@owner)

      assert_match(/No pickable resource types yet/, response.body)
    end
  end

  # #183 review — an STI table holds records of several classes, each with its
  # own declaration, and the model gate judges the RECORD's class. A type-level
  # "no" here would make every Invoice unreachable in the console because
  # Document said no, so the base stays on offer and the RECORD list narrows.
  test "an STI base stays on offer when only a subclass accepts the role" do
    invoice = Invoice.create!(title: "INV-1")
    receipt = Receipt.create!(title: "RCT-1")
    Document.current_scope_grantable_roles = [ "Owner" ]
    Invoice.current_scope_grantable_roles = [ "Member" ]

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Document"),
          headers: as(@owner)

      assert_response :success
      assert_select "option[value=?]", "Document"
      assert_no_match(/type not listed/, response.body)
      assert_select "select[name=resource_gid] option[value=?]", invoice.to_gid.to_s
      assert_select "select[name=resource_gid] option[value=?]", receipt.to_gid.to_s, count: 0
    end
  end

  test "when no record of the type accepts the role, the empty list says why" do
    Receipt.create!(title: "RCT-1")
    Document.current_scope_grantable_roles = [ "Owner" ]

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Document"),
          headers: as(@owner)

      assert_match(/No documents accept/, response.body)
      assert_match(/Member/, response.body)
      assert_no_match(/to pick from yet/, response.body,
                      "there ARE documents — blaming an empty table sends the operator to create one")
    end
  end

  # The documented deep link carries no role_id (#183 review). Reading that nil
  # role as "accepts nothing" dropped the record from the cascade and landed the
  # operator on a blank picker — every other filter here treats it as "nothing
  # chosen yet, nothing to filter by".
  test "a deep link with no role chosen still prefills a type that declares its roles" do
    folder = Folder.create!(name: "Q3 Ledger")
    Folder.current_scope_grantable_roles = [ "Owner" ]

    get current_scope.new_scoped_role_assignment_path(resource_gid: folder.to_gid.to_s), headers: as(@owner)

    assert_response :success
    assert_select "option[selected][value=?]", "Folder"
    assert_select "select[name=resource_gid] option[selected][value=?]", folder.to_gid.to_s
  end

  test "a deep-linked record whose own class refuses the role is not offered" do
    receipt = Receipt.create!(title: "RCT-1")
    Document.current_scope_grantable_roles = [ "Owner" ]

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, subject_gid: @member.to_gid.to_s,
        resource_type: "Document", resource_gid: receipt.to_gid.to_s
      ), headers: as(@owner)

      assert_select "input[type=hidden][name=resource_gid]", count: 0,
                    message: "a Grant button under the hint saying no record accepts the role is the dead end"
      assert_match(/No documents accept/, response.body)
    end
  end

  # An STI table is the one place the role filter runs per record, so on the
  # indexed-search path it has to run BEFORE the display cut (#183 review).
  test "the indexed search finds a grantable record past the first page of refused ones" do
    50.times { |i| Receipt.create!(title: "Doc #{i}") }
    invoice = Invoice.create!(title: "Doc 50")
    Document.current_scope_grantable_roles = [ "Owner" ]
    Invoice.current_scope_grantable_roles = [ "Member" ]
    Document.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_type: "Document", q: "Doc"
      ), headers: as(@owner)

      # The one grantable match sat past the 50-row display cut.
      assert_select "select[name=resource_gid] option[value=?]", invoice.to_gid.to_s, count: 1
    end
  ensure
    Document.singleton_class.send(:remove_method, :current_scope_searchable_scope)
  end

  test "a registered STI leaf is withheld like any other type, because its records answer for themselves" do
    Receipt.current_scope_grantable_roles = [ "Owner" ]

    with_scopeable_resources([ Receipt ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id), headers: as(@owner)

      assert_select "option[value=?]", "Receipt", count: 0
      assert_match(/No resource type accepts/, response.body,
                   "a leaf class answers for itself, so it is withheld outright rather than offered empty")
    end
  end

  # A mid-level STI class is neither root nor leaf: rows queried through Invoice
  # can still load as SpecialInvoice, with SpecialInvoice's own declaration
  # (#183 review).
  test "a mid-level STI class is not treated as a leaf" do
    special = SpecialInvoice.create!(title: "SI-1")
    Invoice.create!(title: "INV-1")
    Invoice.current_scope_grantable_roles = [ "Owner" ]
    SpecialInvoice.current_scope_grantable_roles = [ "Member" ]

    with_scopeable_resources([ Invoice ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Invoice"),
          headers: as(@owner)

      assert_select "option[value=?]", "Invoice"
      assert_select "select[name=resource_gid] option[value=?]", special.to_gid.to_s, count: 1
    end
  end

  # The record does not simply disappear (#183 review): with other grantable
  # records in the list there is nothing on screen to hint at what happened.
  test "a deep-linked record the role refuses is named, not silently dropped" do
    receipt = Receipt.create!(title: "RCT-1")
    invoice = Invoice.create!(title: "INV-1")
    Document.current_scope_grantable_roles = [ "Owner" ]
    Invoice.current_scope_grantable_roles = [ "Member" ]

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_type: "Document", resource_gid: receipt.to_gid.to_s
      ), headers: as(@owner)

      assert_match(/The linked/, response.body)
      assert_match(/RCT-1/, response.body, "and it names the record the operator linked from")
      assert_select "select[name=resource_gid] option[value=?]", invoice.to_gid.to_s,
                    count: 1 # the rest of the list still works
      assert_select "input[type=hidden][name=resource_gid]", count: 0
    end
  end

  test "a search whose every match is refused says to change the role, not the search" do
    # Past SEARCH_THRESHOLD, so the type really offers a search box.
    21.times { |i| Receipt.create!(title: "Quarter close #{i}") }
    Document.current_scope_grantable_roles = [ "Owner" ]
    Document.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_type: "Document", q: "Quarter"
      ), headers: as(@owner)

      assert_match(/accepts\s+<strong>Member/, response.body)
      assert_no_match(/try a different search/, response.body)
    end
  ensure
    Document.singleton_class.send(:remove_method, :current_scope_searchable_scope)
  end

  # The Grant button posts what the operator can SEE selected. A resource_gid
  # survives every autosubmit, so an earlier pick must not ride along after the
  # role or the type moves on (#183 review).
  test "a record picked under one role is not still posted after the role changes" do
    folder = Folder.create!(name: "Q3 Ledger")
    Folder.current_scope_grantable_roles = [ "Owner" ]
    picks = { subject_gid: @member.to_gid.to_s, resource_type: "Folder", resource_gid: folder.to_gid.to_s }

    get current_scope.new_scoped_role_assignment_path(picks.merge(role_id: @owner_role.id)), headers: as(@owner)
    assert_select "input[type=hidden][name=resource_gid][value=?]", folder.to_gid.to_s

    get current_scope.new_scoped_role_assignment_path(picks.merge(role_id: @member_role.id)), headers: as(@owner)
    assert_select "input[type=hidden][name=resource_gid]", count: 0,
                  message: "the type is withheld now, so there is nothing to grant on"
    assert_select "option[value=?]", "Folder", count: 0,
                  message: "and the withheld type is gone from the dropdown with it"
  end

  test "a record picked under one type is not still posted after the type changes" do
    Gadget # autoload ⇒ self-registers, so the type step really moves to Gadget
    folder = Folder.create!(name: "Q3 Ledger")

    get current_scope.new_scoped_role_assignment_path(
      role_id: @member_role.id, subject_gid: @member.to_gid.to_s,
      resource_type: "Gadget", resource_gid: folder.to_gid.to_s
    ), headers: as(@owner)

    assert_response :success
    assert_select "input[type=hidden][name=resource_gid]", count: 0,
                  message: "granting a Folder from the Gadget step would be a grant the operator never saw"
  end

  test "a type that accepts the chosen role is offered" do
    picky = picky_type

    with_scopeable_resources([ Folder, picky ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @owner_role.id), headers: as(@owner)

      assert_select "option[value=?]", "PickyThing"
      assert_no_match(/type not listed/, response.body)
    end
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
