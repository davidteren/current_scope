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

  # The real module, not a hand-rolled double: the picker and the model gate
  # share one predicate, and a double that answers only half of it would let this
  # test pass while the shipped code disagreed with itself (#183 review).
  def picky_type
    Class.new do
      include CurrentScope::GrantableRoles
      def self.name = "PickyThing"
      def self.model_name = ActiveModel::Name.new(self, nil, "PickyThing")
      self.current_scope_grantable_roles = [ "Owner" ] # throwaway class: nothing to restore
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
      assert_select "#cs_types_withheld", /Member/,
                    "and it names the role that was not accepted"
    end
  end

  # The two empties are different (#183 review). Sending an operator whose role
  # matched nothing to "add include CurrentScope::Scopeable" is advice that
  # cannot help them: the types ARE registered.
  test "when every type withholds the role, the page says so rather than blaming setup" do
    with_scopeable_resources([ picky_type ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id), headers: as(@owner)

      assert_response :success
      assert_select "#cs_types_none_accept", /Member/
      assert_select "#cs_types_unregistered", count: 0
    end
  end

  test "with nothing registered at all, the setup advice is still the right advice" do
    with_scopeable_resources([]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id), headers: as(@owner)

      assert_select "#cs_types_unregistered"
    end
  end

  # #183 review — an STI table holds records of several classes, each with its
  # own declaration, and the model gate judges the RECORD's class. A type-level
  # "no" here would make every Invoice unreachable in the console because
  # Document said no, so the base stays on offer and the RECORD list narrows.
  test "an STI base stays on offer when only a subclass accepts the role" do
    invoice = Invoice.create!(title: "INV-1")
    receipt = Receipt.create!(title: "RCT-1")
    declare_grantable_roles(Document, [ "Owner" ])
    declare_grantable_roles(Invoice, [ "Member" ])

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Document"),
          headers: as(@owner)

      assert_response :success
      assert_select "option[value=?]", "Document"
      assert_select "#cs_types_withheld", count: 0
      assert_select "select[name=resource_gid] option[value=?]", invoice.to_gid.to_s
      assert_select "select[name=resource_gid] option[value=?]", receipt.to_gid.to_s, count: 0
    end
  end

  test "when no record of the type accepts the role, the empty list says why" do
    Receipt.create!(title: "RCT-1")
    declare_grantable_roles(Document, [ "Owner" ])

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Document"),
          headers: as(@owner)

      assert_select "#cs_records_refused", /Member/,
                    "there ARE documents — blaming an empty table sends the operator to create one"
    end
  end

  # The documented deep link carries no role_id (#183 review). Reading that nil
  # role as "accepts nothing" dropped the record from the cascade and landed the
  # operator on a blank picker — every other filter here treats it as "nothing
  # chosen yet, nothing to filter by".
  test "a deep link with no role chosen still prefills a type that declares its roles" do
    folder = Folder.create!(name: "Q3 Ledger")
    declare_grantable_roles(Folder, [ "Owner" ])

    get current_scope.new_scoped_role_assignment_path(resource_gid: folder.to_gid.to_s), headers: as(@owner)

    assert_response :success
    assert_select "option[selected][value=?]", "Folder"
    assert_select "select[name=resource_gid] option[selected][value=?]", folder.to_gid.to_s
  end

  test "a deep-linked record whose own class refuses the role is not offered" do
    receipt = Receipt.create!(title: "RCT-1")
    declare_grantable_roles(Document, [ "Owner" ])

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, subject_gid: @member.to_gid.to_s,
        resource_type: "Document", resource_gid: receipt.to_gid.to_s
      ), headers: as(@owner)

      assert_select "input[type=hidden][name=resource_gid]", count: 0,
                    message: "a Grant button under the hint saying no record accepts the role is the dead end"
      assert_select "#cs_records_refused"
    end
  end

  # An STI table is the one place the role filter runs per record, so on the
  # indexed-search path it has to run BEFORE the display cut (#183 review).
  test "the indexed search finds a grantable record past the first page of refused ones" do
    50.times { |i| Receipt.create!(title: "Doc #{i}") }
    invoice = Invoice.create!(title: "Doc 50")
    declare_grantable_roles(Document, [ "Owner" ])
    declare_grantable_roles(Invoice, [ "Member" ])
    Document.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_type: "Document", q: "Doc"
      ), headers: as(@owner)

      # The one grantable match sat past the 50-row display cut.
      assert_select "select[name=resource_gid] option[value=?]", invoice.to_gid.to_s, count: 1
    end
  ensure
    # Guarded: the hook is defined several statements in, and an unguarded
    # remove_method would raise NameError over the real failure.
    if Document.singleton_class.method_defined?(:current_scope_searchable_scope)
      Document.singleton_class.send(:remove_method, :current_scope_searchable_scope)
    end
  end

  # Even a leaf: the picker cannot ask a TABLE which classes its rows will load
  # as without depending on what happens to be autoloaded, and offering a type
  # whose records all refuse costs one dropdown entry, while withholding one
  # whose records are grantable hides them with no way back (#183 review).
  test "a class over an STI table stays on offer, and its record list carries the refusal" do
    Receipt.create!(title: "RCT-1")
    declare_grantable_roles(Receipt, [ "Owner" ])

    with_scopeable_resources([ Receipt ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Receipt"),
          headers: as(@owner)

      assert_select "option[value=?]", "Receipt"
      assert_select "#cs_records_refused"
      assert_select "input[type=hidden][name=resource_gid]", count: 0
    end
  end

  # A surviving deep-linked record is selected and grantable, so telling the
  # operator that nothing matching accepts the role would contradict the Grant
  # button right above it (#183 review).
  test "a zero-match search does not tell the operator to change a role that already works" do
    21.times { |i| Receipt.create!(title: "RCT-#{i}") }
    invoice = Invoice.create!(title: "INV-1")
    declare_grantable_roles(Document, [ "Owner" ])
    declare_grantable_roles(Invoice, [ "Member" ])

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, subject_gid: @member.to_gid.to_s, resource_type: "Document",
        resource_gid: invoice.to_gid.to_s, q: "RCT"
      ), headers: as(@owner)

      assert_select "input[type=hidden][name=resource_gid][value=?]", invoice.to_gid.to_s
      assert_select "#cs_search_refused", count: 0
      # And no "no records match" either: records DID match, and the role filter
      # is what removed them (#183 review).
      assert_select "#cs_search_none", count: 0
    end
  end

  # A mid-level STI class is neither root nor leaf: rows queried through Invoice
  # can still load as SpecialInvoice, with SpecialInvoice's own declaration
  # (#183 review).
  test "a mid-level STI class is not treated as a leaf" do
    special = SpecialInvoice.create!(title: "SI-1")
    Invoice.create!(title: "INV-1")
    declare_grantable_roles(Invoice, [ "Owner" ])
    declare_grantable_roles(SpecialInvoice, [ "Member" ])

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
    declare_grantable_roles(Document, [ "Owner" ])
    declare_grantable_roles(Invoice, [ "Member" ])

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_type: "Document", resource_gid: receipt.to_gid.to_s
      ), headers: as(@owner)

      assert_select "#cs_resource_refused", /RCT-1/,
                    "and it names the record the operator linked from"
      assert_select "select[name=resource_gid] option[value=?]", invoice.to_gid.to_s,
                    count: 1 # the rest of the list still works
      assert_select "input[type=hidden][name=resource_gid]", count: 0
    end
  end

  test "a search whose every match is refused says to change the role, not the search" do
    # Past SEARCH_THRESHOLD, so the type really offers a search box.
    21.times { |i| Receipt.create!(title: "Quarter close #{i}") }
    declare_grantable_roles(Document, [ "Owner" ])
    Document.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_type: "Document", q: "Quarter"
      ), headers: as(@owner)

      assert_select "#cs_search_refused", /Member/
      assert_select "#cs_search_none", count: 0
    end
  ensure
    # Guarded: the hook is defined several statements in, and an unguarded
    # remove_method would raise NameError over the real failure.
    if Document.singleton_class.method_defined?(:current_scope_searchable_scope)
      Document.singleton_class.send(:remove_method, :current_scope_searchable_scope)
    end
  end

  # The role filter runs over the SCANNED rows, so with an indexed scope a
  # grantable record can sit past the window. Taking the search box away with
  # the list would leave no way to reach it, and the empty state would be a
  # claim the code cannot make.
  test "an empty role-filtered list keeps the search box where searching can reach further" do
    now = Time.current
    rows = Array.new(CurrentScope::ScopedRoleAssignmentsController::SCAN_CAP) do |i|
      { title: "RCT-#{i}", type: "Receipt", created_at: now, updated_at: now }
    end
    Document.insert_all(rows)
    declare_grantable_roles(Document, [ "Owner" ])
    Document.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Document"),
          headers: as(@owner)

      assert_select "input[name=q]"
      assert_select "#cs_records_refused_searchable"
    end
  ensure
    # Guarded: the hook is defined several statements in, and an unguarded
    # remove_method would raise NameError over the real failure.
    if Document.singleton_class.method_defined?(:current_scope_searchable_scope)
      Document.singleton_class.send(:remove_method, :current_scope_searchable_scope)
    end
  end

  # The search hint carries the same distinction the empty list does: matches
  # that all refuse, with the search itself stopped at its cap, leave somewhere
  # left to look (#183 review).
  test "a search that filled its cap with refused matches says to narrow it, not to give up on the role" do
    now = Time.current
    rows = Array.new(CurrentScope::ScopedRoleAssignmentsController::SCAN_CAP) do |i|
      { title: "RCT-#{i}", type: "Receipt", created_at: now, updated_at: now }
    end
    Document.insert_all(rows)
    declare_grantable_roles(Document, [ "Owner" ])
    Document.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_type: "Document", q: "RCT"
      ), headers: as(@owner)

      assert_select "#cs_search_refused_searchable", /Member/
      assert_select "#cs_search_refused", count: 0
    end
  ensure
    if Document.singleton_class.method_defined?(:current_scope_searchable_scope)
      Document.singleton_class.send(:remove_method, :current_scope_searchable_scope)
    end
  end

  # And the third case: an indexed scope, but the scan already read the whole
  # table. There is nothing left for a search to find, so telling the operator
  # to search would be advice that provably cannot succeed (#183 review).
  test "a fully read table does not suggest searching, even with an indexed scope" do
    21.times { |i| Receipt.create!(title: "RCT-#{i}") }
    declare_grantable_roles(Document, [ "Owner" ])
    Document.define_singleton_method(:current_scope_searchable_scope) { |_term| all }

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Document"),
          headers: as(@owner)

      assert_select "#cs_records_refused"
      assert_select "#cs_records_refused_searchable", count: 0
    end
  ensure
    if Document.singleton_class.method_defined?(:current_scope_searchable_scope)
      Document.singleton_class.send(:remove_method, :current_scope_searchable_scope)
    end
  end

  # And the other half: without an indexed scope a search re-reads the very rows
  # the empty list came from, so offering it would be advice that cannot work.
  test "an empty role-filtered list offers no search where searching cannot reach further" do
    21.times { |i| Receipt.create!(title: "Doc #{i}") }
    declare_grantable_roles(Document, [ "Owner" ])

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id, resource_type: "Document"),
          headers: as(@owner)

      assert_select "input[name=q]", count: 0
      assert_select "#cs_records_refused"
      assert_select "#cs_records_refused_searchable", count: 0
    end
  end

  # The picker withholds the button; the model is the gate. Nothing was covering
  # the path between them — a hand-built POST — and it depends on the refusal
  # landing on :role, or grant_one would swallow it as "already granted".
  test "a grant posted straight to create is refused when the type does not accept the role" do
    folder = Folder.create!(name: "Q3 Ledger")
    declare_grantable_roles(Folder, [ "Owner" ])

    assert_no_difference -> { CurrentScope::ScopedRoleAssignment.count } do
      post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
        role_id: @member_role.id, subject_gid: @member.to_gid.to_s, resource_gid: folder.to_gid.to_s
      }
    end

    assert_redirected_to current_scope.subjects_url
    assert_match(/cannot be granted on Folder/, flash[:alert])
  end

  # A deep-linked record can accept the role while every SCANNED row refuses it.
  # Falling through to the empty state there would leave a Grant button posting
  # a record the page never shows (#183 review).
  test "a deep-linked record past the scan window is shown, not just granted" do
    now = Time.current
    rows = Array.new(CurrentScope::ScopedRoleAssignmentsController::SCAN_CAP) do |i|
      { title: "RCT-#{i}", type: "Receipt", created_at: now, updated_at: now }
    end
    Document.insert_all(rows)
    invoice = Invoice.create!(title: "INV-1")
    declare_grantable_roles(Document, [ "Owner" ])
    declare_grantable_roles(Invoice, [ "Member" ])

    with_scopeable_resources([ Document ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, subject_gid: @member.to_gid.to_s,
        resource_type: "Document", resource_gid: invoice.to_gid.to_s
      ), headers: as(@owner)

      assert_select "select[name=resource_gid] option[selected][value=?]", invoice.to_gid.to_s
      assert_select "input[type=hidden][name=resource_gid][value=?]", invoice.to_gid.to_s
    end
  end

  # A type reached by deep link need not be registered as Scopeable, so the
  # "no type accepts this role" state must give way to one that did resolve —
  # otherwise a grantable target is thrown away to print something untrue.
  test "a deep link still works when every registered type withholds the role" do
    project = Project.create!(name: "Q3")
    report = Report.create!(title: "Q3 report", project: project, requested_by: @owner)
    declare_grantable_roles(Folder, [ "Owner" ])

    with_scopeable_resources([ Folder ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, subject_gid: @member.to_gid.to_s, resource_gid: report.to_gid.to_s
      ), headers: as(@owner)

      assert_response :success
      assert_select "option[selected][value=?]", "Report"
      assert_select "input[type=hidden][name=resource_gid][value=?]", report.to_gid.to_s
      assert_select "#cs_types_none_accept", count: 0
    end
  end

  test "a refused deep link is explained even when there is no type left to show" do
    folder = Folder.create!(name: "Q3 Ledger")
    declare_grantable_roles(Folder, [ "Owner" ])

    with_scopeable_resources([ Folder ]) do
      get current_scope.new_scoped_role_assignment_path(
        role_id: @member_role.id, resource_gid: folder.to_gid.to_s
      ), headers: as(@owner)

      assert_select "#cs_resource_refused", /Q3 Ledger/
      assert_select "#cs_types_none_accept"
    end
  end

  # A stale bookmark can name a role that no longer exists. Reading that as "no
  # role chosen" would show every type and every record with no hint, and leave
  # a Grant button that can only fail on POST (#183 review).
  test "a role id that no longer resolves is said out loud, and grants nothing" do
    folder = Folder.create!(name: "Q3 Ledger")
    gone = CurrentScope::Role.create!(name: "Temp")
    gone_id = gone.id
    gone.destroy!

    get current_scope.new_scoped_role_assignment_path(
      role_id: gone_id, subject_gid: @member.to_gid.to_s,
      resource_type: "Folder", resource_gid: folder.to_gid.to_s
    ), headers: as(@owner)

    assert_response :success
    assert_select "#cs_role_missing"
    assert_select "input[type=hidden][name=resource_gid]", count: 0
  end

  # Without JavaScript this submit is the only way to re-run the cascade, and a
  # role every type withholds is recoverable — by changing the role, which needs
  # a control to submit (#183 review).
  test "the state where no type accepts the role keeps the no-JS submit" do
    with_scopeable_resources([ picky_type ]) do
      get current_scope.new_scoped_role_assignment_path(role_id: @member_role.id), headers: as(@owner)

      assert_select "#cs_types_none_accept"
      assert_select ".cs-picker-refresh"
    end
  end

  # The browser preselects the first option, so without a blank the page would
  # show a role the server has not applied, beside a type list that ignores it.
  test "the first render selects no role, because the server has applied none" do
    get current_scope.new_scoped_role_assignment_path, headers: as(@owner)

    assert_select "select[name=role_id] option[selected]", count: 0
    assert_select "select[name=role_id] option[value='']"
  end

  # The Grant button posts what the operator can SEE selected. A resource_gid
  # survives every autosubmit, so an earlier pick must not ride along after the
  # role or the type moves on (#183 review).
  test "a record picked under one role is not still posted after the role changes" do
    folder = Folder.create!(name: "Q3 Ledger")
    declare_grantable_roles(Folder, [ "Owner" ])
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
      assert_select "#cs_types_withheld", count: 0
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

    assert_select "#cs_search_none"
    assert_select "#cs_search_shown", count: 0
    # The field that holds the query stays, or the advice to change it is
    # unreachable.
    assert_select "input[name=q]", count: 1
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
    assert_select "#cs_search_none"
    assert_select "#cs_search_shown", count: 0
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
