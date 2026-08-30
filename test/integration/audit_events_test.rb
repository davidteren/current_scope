require "test_helper"
require "current_scope/test_helpers"

# Every authorization mutation must leave exactly one transactional trace. These
# drive the six controller mutation sites end to end (events are recorded inside
# real requests, so the ambient actor comes from Context), plus the impersonation
# boundary API and the read-only ledger index.
class AuditEventsTest < ActionDispatch::IntegrationTest
  include CurrentScope::TestHelpers

  setup do
    @owner = User.create!(name: "Owner")
    @member = User.create!(name: "Member")
    @owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @member_role = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    CurrentScope::RoleAssignment.create!(subject: @member, role: @member_role)
    # The boundary-API tests below record impersonation events, which now require
    # a configured actor_method (recording a boundary event without one is the
    # A2 misconfiguration the engine refuses). A valid impersonation setup has it.
    @original_actor_method = CurrentScope.config.actor_method
    CurrentScope.config.actor_method = :true_user
  end

  teardown do
    CurrentScope.config.actor_method = @original_actor_method
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  def only_event
    assert_equal 1, CurrentScope::Event.count, "expected exactly one event"
    CurrentScope::Event.first
  end

  # #182 made every grant write audited, including the ones a test makes while
  # ARRANGING. Clearing here narrows each assertion back to the action under
  # test; that model-level writes are audited at all is asserted on its own
  # below, where it is the point rather than noise.
  def only_from_here
    CurrentScope::Event.delete_all
  end

  # --- #182: every write path leaves the same trail ---
  #
  # The console recorded its own events, so a grant re-derived by the seed task
  # left nothing behind. After a role delete cascaded revocations into the
  # ledger, restoring every one of them added no rows, and an auditor reading
  # later saw the revocations, found no restoration, and would reasonably
  # conclude access was still gone when it was fully restored.

  test "a grant created through the model API is audited, with no request behind it" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    only_from_here

    assert_difference -> { CurrentScope::Event.count }, 1 do
      CurrentScope::ScopedRoleAssignment.create!(subject: @member, resource: report, role: @member_role)
    end

    event = only_event
    assert_equal "scoped_role.granted", event.event
    assert_equal @member.to_gid.to_s, event.target
    assert_equal "Member", event.details["role"]
    assert_equal "Q3", event.details["resource"]
    assert_equal "self", event.details["attribution"],
      "nothing had set an ambient actor, so the row is attributed to the grantee"
  end

  test "a grant destroyed through the model API is audited too" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    grant = CurrentScope::ScopedRoleAssignment.create!(subject: @member, resource: report, role: @member_role)
    only_from_here

    assert_difference -> { CurrentScope::Event.count }, 1 do
      grant.destroy!
    end

    assert_equal "scoped_role.revoked", only_event.event
  end

  # The incident this issue was filed from, end to end: a role is deleted
  # through the console, its grants cascade, and the seed task restores them.
  # The ledger has to show both halves.
  test "a restore after a cascading role delete is visible in the ledger" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    doomed = CurrentScope::Role.create!(name: "Doomed")
    CurrentScope::ScopedRoleAssignment.create!(subject: @member, resource: report, role: doomed)
    only_from_here

    delete current_scope.role_url(doomed), headers: as(@owner)
    assert_equal 1, CurrentScope::Event.where(event: "scoped_role.revoked").count

    # The restore, exactly as a seed does it: model API, no request.
    restored = CurrentScope::Role.create!(name: "Doomed")
    CurrentScope::ScopedRoleAssignment.find_or_create_by!(subject: @member, resource: report, role: restored)

    granted = CurrentScope::Event.where(event: "scoped_role.granted").last
    assert granted, "the restoration has to be in the ledger, or the revocations read as final"
    assert_equal "self", granted.details["attribution"]
  end

  # #182 review — with auditing off, a grant write must do NO audit work at all,
  # not merely discard the row at the end. Each recorder resolves a polymorphic
  # subject and a resource label to build one, which is two queries per grant on
  # a host that asked for none; the seed that motivated this issue restores 187.
  test "no audit work happens at all when auditing is off" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    CurrentScope.config.audit = false
    CurrentScope::ScopedRoleAssignment.define_singleton_method(:audit_probe) { true }

    grant = CurrentScope::ScopedRoleAssignment.new(subject: @member, resource: report, role: @member_role)
    grant.define_singleton_method(:audit_subject) { raise "resolved a record for a row nobody wanted" }
    grant.define_singleton_method(:audit_resource_label) { raise "built a label for a row nobody wanted" }

    assert_nothing_raised { grant.save! }
    assert_nothing_raised { grant.destroy! }
  ensure
    CurrentScope.config.audit = true
  end

  # #182 review — the field is only useful if it is on every event. An auditor
  # filtering for human-driven changes must not silently lose org-role
  # assignments and role edits because those emitters predate it.
  test "every event that changes an authorization carries an attribution" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    other = User.create!(name: "Other")
    only_from_here

    post current_scope.role_assignments_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: @member_role.id }
    post current_scope.roles_url, headers: as(@owner),
         params: { role: { name: "Fresh" }, permission_keys: [] }
    CurrentScope::ScopedRoleAssignment.create!(subject: @member, resource: report, role: @member_role)

    # The FAMILY, named: a loop over Event.all would pass while an emitter
    # outside this list stayed sourceless, and would fail the day an
    # observation event (which deliberately carries none) landed in the same
    # window.
    CurrentScope.grant!(User.create!(name: "Bootstrapped"), role: @member_role)

    changes = %w[org_role.assigned role.created scoped_role.granted]
    changes.each do |name|
      rows = CurrentScope::Event.where(event: name).to_a
      assert rows.any?, "expected a #{name} row from this arrangement"
      # EVERY row of that name, not the first: org_role.assigned is written by
      # the console AND by CurrentScope.grant!, and checking one would leave the
      # other free to carry nothing.
      rows.each do |event|
        assert event.details["attribution"].present?,
          "a #{name} row carries no attribution, so a filter on it would lose it"
      end
    end
  end

  test "a write with an ambient actor says so" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    only_from_here

    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      subject_gid: @member.to_gid.to_s, resource_gid: report.to_gid.to_s, role_id: @member_role.id
    }

    assert_equal "actor", only_event.details["attribution"],
      "the request set CurrentScope::Current.actor; the field claims no more than that"
  end

  # Minitest 6 dropped minitest/mock, so swap record! for a raiser by hand and
  # restore the original Method object afterwards.
  def with_failing_event_record
    original = CurrentScope::Event.method(:record!)
    CurrentScope::Event.define_singleton_method(:record!) { |*, **| raise "event write failed" }
    yield
  ensure
    CurrentScope::Event.define_singleton_method(:record!, original)
  end

  # --- roles#create --------------------------------------------------------

  test "roles#create emits exactly one role.created folding the initial perms" do
    assert_difference -> { CurrentScope::Event.count }, 1 do
      post current_scope.roles_url, headers: as(@owner),
           params: { role: { name: "Auditor", full_access: "0",
                             permission_keys: [ "", "reports#index", "reports#show" ] } }
    end
    role = CurrentScope::Role.find_by!(name: "Auditor")
    event = only_event

    assert_equal "role.created", event.event
    assert_equal role.to_gid.to_s, event.target
    assert_equal "Auditor", event.details["name"]
    assert_equal [ "reports#index", "reports#show" ].sort, event.details["permission_keys"].sort
    # #30 — Context stamps request.request_id so ledger rows correlate with logs
    assert event.request_id.present?, "UI mutations must carry a request_id"
    assert_equal request.request_id, event.request_id
  end

  test "a failed roles#create (invalid) emits no event" do
    assert_no_difference -> { CurrentScope::Event.count } do
      post current_scope.roles_url, headers: as(@owner),
           params: { role: { name: "", full_access: "0" } }
    end
  end

  # --- roles#update --------------------------------------------------------

  test "roles#update grid change emits role.updated carrying the {added:, removed:} diff" do
    @member_role.update!(permission_keys: [ "reports#index" ])

    patch current_scope.role_url(@member_role), headers: as(@owner), params: {
      role: { name: "Member", full_access: "0", permission_keys: [ "", "reports#show" ] }
    }
    event = only_event

    assert_equal "role.updated", event.event
    assert_equal @member_role.to_gid.to_s, event.target
    assert_equal [ "reports#show" ], event.details["added"]
    assert_equal [ "reports#index" ], event.details["removed"]
  end

  test "roles#update rename emits role.renamed carrying old and new name plus the diff" do
    @member_role.update!(permission_keys: [ "reports#index" ])

    patch current_scope.role_url(@member_role), headers: as(@owner), params: {
      role: { name: "Auditors", full_access: "0", permission_keys: [ "", "reports#show" ] }
    }
    event = only_event

    assert_equal "role.renamed", event.event
    assert_equal "Member", event.details["old_name"]
    assert_equal "Auditors", event.details["new_name"]
    assert_equal [ "reports#show" ], event.details["added"]
    assert_equal [ "reports#index" ], event.details["removed"]
  end

  test "a no-op roles#update (same name, identical grid re-save) emits nothing" do
    @member_role.update!(permission_keys: [ "reports#index" ])

    assert_no_difference -> { CurrentScope::Event.count } do
      patch current_scope.role_url(@member_role), headers: as(@owner), params: {
        role: { name: "Member", full_access: "0", permission_keys: [ "", "reports#index" ] }
      }
    end
  end

  test "roles#update full_access toggle emits role.updated with from/to" do
    other = User.create!(name: "CoOwner")
    co = CurrentScope::Role.create!(name: "CoOwner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: other, role: co)

    only_from_here
    patch current_scope.role_url(@owner_role), headers: as(@owner), params: {
      role: { name: "Owner", full_access: "0", permission_keys: [ "" ] }
    }
    event = only_event

    assert_equal "role.updated", event.event
    assert_equal true, event.details["full_access_from"]
    assert_equal false, event.details["full_access_to"]
    assert_not @owner_role.reload.full_access?
  end

  # --- roles#destroy -------------------------------------------------------

  test "roles#destroy emits role.deleted plus one cascade event per assignment (pre-destroy snapshot)" do
    grantee = User.create!(name: "Grantee") # no org role yet ⇒ can hold Doomed org-wide
    report = Report.create!(title: "Q3", requested_by: @owner)
    doomed = CurrentScope::Role.create!(name: "Doomed")
    CurrentScope::RoleAssignment.create!(subject: grantee, role: doomed)
    CurrentScope::ScopedRoleAssignment.create!(subject: @owner, resource: report, role: doomed)

    only_from_here
    delete current_scope.role_url(doomed), headers: as(@owner)
    assert_redirected_to current_scope.roles_url

    events = CurrentScope::Event.all.to_a
    assert_equal 3, events.size

    deleted = events.find { |e| e.event == "role.deleted" }
    assert_equal doomed.to_gid.to_s, deleted.target

    org = events.find { |e| e.event == "org_role.removed" }
    assert_equal grantee.to_gid.to_s, org.target # target = the grantee
    assert_equal "Doomed", org.details["role"]

    scoped = events.find { |e| e.event == "scoped_role.revoked" }
    assert_equal @owner.to_gid.to_s, scoped.target # target = the grantee
    assert_equal "Doomed", scoped.details["role"]
  end

  # --- role_assignments#create (set / change / clear) ----------------------

  test "role_assignments#create set (no prior) emits org_role.assigned targeting the grantee" do
    other = User.create!(name: "Other")

    post current_scope.role_assignments_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: @member_role.id }
    event = only_event

    assert_equal "org_role.assigned", event.event
    assert_equal other.to_gid.to_s, event.target
    assert_equal "Member", event.details["role"]
  end

  test "role_assignments#create change (different prior) emits org_role.changed carrying the prior role" do
    other = User.create!(name: "Other")
    CurrentScope::RoleAssignment.create!(subject: other, role: @member_role)

    only_from_here
    post current_scope.role_assignments_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: @owner_role.id }
    event = only_event

    assert_equal "org_role.changed", event.event
    assert_equal other.to_gid.to_s, event.target
    assert_equal "Member", event.details["from"]
    assert_equal "Owner", event.details["to"]
  end

  test "role_assignments#create clear (blank, prior existed) emits org_role.removed" do
    other = User.create!(name: "Other")
    CurrentScope::RoleAssignment.create!(subject: other, role: @member_role)

    only_from_here
    post current_scope.role_assignments_url, headers: as(@owner),
         params: { subject_gid: other.to_gid.to_s, role_id: "" }
    event = only_event

    assert_equal "org_role.removed", event.event
    assert_equal other.to_gid.to_s, event.target
    assert_equal "Member", event.details["role"]
  end

  test "role_assignments#create same-role re-set emits nothing" do
    other = User.create!(name: "Other")
    CurrentScope::RoleAssignment.create!(subject: other, role: @member_role)

    only_from_here
    assert_no_difference -> { CurrentScope::Event.count } do
      post current_scope.role_assignments_url, headers: as(@owner),
           params: { subject_gid: other.to_gid.to_s, role_id: @member_role.id }
    end
  end

  test "role_assignments#create clear with no prior emits nothing" do
    other = User.create!(name: "Other")

    assert_no_difference -> { CurrentScope::Event.count } do
      post current_scope.role_assignments_url, headers: as(@owner),
           params: { subject_gid: other.to_gid.to_s, role_id: "" }
    end
  end

  # --- scoped_role_assignments#create / #destroy ---------------------------

  test "scoped_role_assignments#create emits scoped_role.granted targeting the grantee" do
    report = Report.create!(title: "Q3", requested_by: @owner)

    post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
      subject_gid: @member.to_gid.to_s, resource_gid: report.to_gid.to_s, role_id: @member_role.id
    }
    event = only_event

    assert_equal "scoped_role.granted", event.event
    assert_equal @member.to_gid.to_s, event.target
    assert_equal "Member", event.details["role"]
    assert_equal "Q3", event.details["resource"]
  end

  test "scoped_role_assignments#destroy emits scoped_role.revoked targeting the grantee" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: @member, resource: report, role: @member_role)

    only_from_here
    delete current_scope.scoped_role_assignment_url(sra), headers: as(@owner)
    event = only_event

    assert_equal "scoped_role.revoked", event.event
    assert_equal @member.to_gid.to_s, event.target
    assert_equal "Member", event.details["role"]
    assert_equal "Q3", event.details["resource"]
  end

  test "a failed scoped_role_assignments#create (duplicate) emits nothing" do
    report = Report.create!(title: "Q3", requested_by: @owner)
    CurrentScope::ScopedRoleAssignment.create!(subject: @member, resource: report, role: @member_role)

    only_from_here
    assert_no_difference -> { CurrentScope::Event.count } do
      post current_scope.scoped_role_assignments_url, headers: as(@owner), params: {
        subject_gid: @member.to_gid.to_s, resource_gid: report.to_gid.to_s, role_id: @member_role.id
      }
    end
  end

  # --- transactional atomicity ---------------------------------------------

  test "an event-write failure rolls back the grant" do
    other = User.create!(name: "Other")

    assert_raises(RuntimeError) do
      with_failing_event_record do
        post current_scope.role_assignments_url, headers: as(@owner),
             params: { subject_gid: other.to_gid.to_s, role_id: @member_role.id }
      end
    end

    assert_nil CurrentScope::RoleAssignment.find_by(subject: other), "grant must roll back with the failed event"
  end

  # --- boundary API --------------------------------------------------------

  test "record_impersonation_started! targets the impersonated subject while the ambient pair reads actor == user" do
    event = with_current_user(@owner) do
      CurrentScope.record_impersonation_started!(@member)
    end

    assert_equal "impersonation.started", event.event
    assert_equal @owner.to_gid.to_s, event.actor   # ambient actor
    assert_equal @owner.to_gid.to_s, event.subject # ambient pair: actor == user
    assert_equal @member.to_gid.to_s, event.target # the EXPLICIT impersonated subject
  end

  test "record_impersonation_stopped! writes impersonation.stopped targeting the subject" do
    event = with_current_user(@owner) { CurrentScope.record_impersonation_stopped!(@member) }

    assert_equal "impersonation.stopped", event.event
    assert_equal @member.to_gid.to_s, event.target
  end

  # --- events index (read-only) --------------------------------------------

  test "events index renders for a full-access subject" do
    with_current_user(@owner) { CurrentScope.record_impersonation_started!(@member) }

    get current_scope.events_url, headers: as(@owner)
    assert_response :success
    assert_match "impersonation.started", response.body
  end

  test "events index renders a reserved definitions target without 500" do
    with_current_user(@owner) do
      CurrentScope::Event.record!(
        event: "definitions.applied",
        target: CurrentScope::Event::DEFINITIONS_TARGET
      )
    end

    get current_scope.events_url, headers: as(@owner)
    assert_response :success
    assert_match "definitions.applied", response.body
    assert_match "Role definitions", response.body
  end

  test "events index 403s below full access and for anonymous" do
    get current_scope.events_url, headers: as(@member)
    assert_response :forbidden

    get current_scope.events_url
    assert_response :forbidden
  end

  test "events index honors the hard limit" do
    role = CurrentScope::Role.create!(name: "Noise")
    205.times do |i|
      with_current_user(@owner) { CurrentScope::Event.record!(event: "role.created", target: role, details: { n: i }) }
    end

    get current_scope.events_url, headers: as(@owner)
    assert_response :success
    # 200-row cap ⇒ the oldest rows fall off; assert the view rendered the cap, not all 205.
    assert_operator response.body.scan("role.created").size, :<=, 200
  end

  test "a target_label containing markup renders escaped in the index" do
    # The role name flows into target_label; a hostile name must not become live
    # markup in the ledger.
    post current_scope.roles_url, headers: as(@owner),
         params: { role: { name: "<script>alert('x')</script>", full_access: "0" } }

    get current_scope.events_url, headers: as(@owner)
    assert_response :success
    assert_not_includes response.body, "<script>alert('x')</script>"
    assert_includes response.body, "&lt;script&gt;"
  end
end
