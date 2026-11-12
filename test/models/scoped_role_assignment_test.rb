require "test_helper"

class ScopedRoleAssignmentTest < ActiveSupport::TestCase
  test "orphaned_resource? is false while the resource exists" do
    user = User.create!(name: "U")
    folder = Folder.create!(name: "Live")
    role = CurrentScope::Role.create!(name: "Editor")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: folder, role: role)

    assert_not sra.orphaned_resource?
  end

  test "orphaned_resource? is true after the resource is destroyed" do
    user = User.create!(name: "U")
    folder = Folder.create!(name: "Dead")
    role = CurrentScope::Role.create!(name: "Editor")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: folder, role: role)
    folder.destroy!

    assert sra.reload.orphaned_resource?
  end

  test "orphaned_resource? is true when resource_type does not constantize" do
    user = User.create!(name: "U")
    folder = Folder.create!(name: "X")
    role = CurrentScope::Role.create!(name: "Editor")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: folder, role: role)
    sra.update_column(:resource_type, "NoSuchModel")

    assert sra.orphaned_resource?
  end

  test "orphaned_resource? is memoized across repeated calls" do
    user = User.create!(name: "U")
    folder = Folder.create!(name: "Live")
    role = CurrentScope::Role.create!(name: "Editor")
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: folder, role: role)

    assert_not sra.orphaned_resource?
    assert_same sra.orphaned_resource?, sra.orphaned_resource?
  end

  test "preload_resolvable_resources! loads live types and leaves stale types unloaded" do
    user = User.create!(name: "U")
    live_folder = Folder.create!(name: "Live")
    other_folder = Folder.create!(name: "Other")
    role = CurrentScope::Role.create!(name: "Editor")
    live = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: live_folder, role: role)
    stale = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: other_folder, role: role)
    stale.update_column(:resource_type, "NoSuchModel")
    stale = CurrentScope::ScopedRoleAssignment.find(stale.id) # drop cached association

    rows = [ live, stale ]
    CurrentScope::ScopedRoleAssignment.preload_resolvable_resources!(rows)

    assert live.association(:resource).loaded?
    assert_equal live_folder, live.resource
    assert_not stale.association(:resource).loaded?
    assert stale.orphaned_resource?
  end

  test "preload marks an unsupported key shape inert instead of leaving it lazy" do
    user = User.create!(name: "U")
    project = Project.create!(name: "Legacy")
    role = CurrentScope::Role.create!(name: "Editor")
    row = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: project, role: role)
    row = CurrentScope::ScopedRoleAssignment.find(row.id)
    original_key = Project.primary_key
    Project.primary_key = [ "id", "name" ]

    CurrentScope::ScopedRoleAssignment.preload_resolvable_resources!([ row ])

    assert row.association(:resource).loaded?
    assert_nil row.resource
    assert row.orphaned_resource?
  ensure
    Project.primary_key = original_key
  end

  test "a non-canonical legacy id never resolves to an unrelated live resource" do
    user = User.create!(name: "U")
    project = Project.create!(name: "Seven")
    role = CurrentScope::Role.create!(name: "Editor")
    row = CurrentScope::ScopedRoleAssignment.create!(subject: user, resource: project, role: role)
    row.update_columns(resource_id: "#{project.id}f00-wrong")
    row = CurrentScope::ScopedRoleAssignment.find(row.id)

    assert_nil row.current_scope_resolved_record("resource")
    assert row.orphaned_resource?
  end

  # The SUBJECT side of the same guarantee. The members list, the revoke audit
  # event, and the console grant survey all label from the subject, so a
  # non-canonical stored subject_id must not resolve to an unrelated live subject
  # (which the raw association would, by casting the string through the key type).
  test "a non-canonical legacy subject id never resolves to an unrelated live subject" do
    victim = User.create!(name: "Victim")
    project = Project.create!(name: "P")
    role = CurrentScope::Role.create!(name: "Editor")
    row = CurrentScope::ScopedRoleAssignment.create!(subject: victim, resource: project, role: role)
    # A UUID-shaped id that String#to_i collapses back onto victim.id.
    row.update_columns(subject_id: "#{victim.id}f00aaaa-wrong")
    row = CurrentScope::ScopedRoleAssignment.find(row.id)

    assert_equal victim, row.subject,
                 "the raw association still casts the collapsed id to a live record — that is the hazard"
    assert_nil row.current_scope_resolved_record("subject"),
               "the canonical guard must return nil, not the unrelated live subject"
  end

  def scoped_grant
    holder = User.create!(name: "Holder")
    folder = Folder.create!(name: "Folder")
    role = CurrentScope::Role.create!(name: "Editor #{SecureRandom.hex(4)}")
    CurrentScope::ScopedRoleAssignment.create!(subject: holder, role: role, resource: folder)
  end

  def revoked_events
    CurrentScope::Event.where(event: "scoped_role.revoked")
  end

  test "two handles destroying one scoped role write one revoke event" do
    grant = scoped_grant
    other = CurrentScope::ScopedRoleAssignment.find(grant.id)

    assert_difference -> { revoked_events.count }, 1 do
      grant.destroy!
      other.destroy!
    end
    assert_not CurrentScope::ScopedRoleAssignment.exists?(grant.id)
  end

  test "a recreated scoped role writes its own revoke event" do
    grant = scoped_grant
    holder = grant.subject
    folder = grant.resource
    role = grant.role
    grant.destroy!
    assert_equal 1, revoked_events.count

    again = CurrentScope::ScopedRoleAssignment.create!(subject: holder, role: role, resource: folder)
    assert_not_equal grant.id, again.id

    assert_difference -> { revoked_events.count }, 1 do
      again.destroy!
    end
  end

  test "audit off writes no revoke event for either handle" do
    grant = scoped_grant
    other = CurrentScope::ScopedRoleAssignment.find(grant.id)
    original = CurrentScope.config.audit
    CurrentScope.config.audit = false

    assert_no_difference -> { revoked_events.count } do
      grant.destroy!
      other.destroy!
    end
  ensure
    CurrentScope.config.audit = original
  end

  test "strict audit rolls a scoped revoke back with the event" do
    grant = scoped_grant
    original = CurrentScope.config.audit
    CurrentScope.config.audit = :strict
    create = CurrentScope::Event.method(:create!)
    CurrentScope::Event.define_singleton_method(:create!) do |*, **|
      raise ActiveRecord::StatementInvalid, "SQLite3::SQLException: no such table: current_scope_events"
    end

    assert_no_difference -> { revoked_events.count } do
      assert_raises(ActiveRecord::StatementInvalid) { grant.destroy! }
    end
    assert CurrentScope::ScopedRoleAssignment.exists?(grant.id)
  ensure
    CurrentScope::Event.define_singleton_method(:create!, create) if create
    CurrentScope.config.audit = original
  end
end
