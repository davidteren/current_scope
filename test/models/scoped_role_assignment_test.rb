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
end
