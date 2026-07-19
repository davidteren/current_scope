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
