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
end
