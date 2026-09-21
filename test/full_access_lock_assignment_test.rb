require "test_helper"

# Direct pins for the assignment-removal guards added in #218. Integration
# tests go through HTTP and miss the early-return mutants Mutineer found:
# a non-full-access row, an empty list, a leftover orphan as the last row,
# and registry_blind? while another live holder remains.
class FullAccessLockAssignmentTest < ActiveSupport::TestCase
  setup do
    @owner = User.create!(name: "Owner")
    @owner_role = CurrentScope::Role.create!(name: "Owner", full_access: true)
    @owner_assignment = CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    @member_role = CurrentScope::Role.create!(name: "Member")
    @original_polymorphic_names = CurrentScope.config.polymorphic_class_names
  end

  teardown do
    CurrentScope.config.polymorphic_class_names = @original_polymorphic_names
    CurrentScope.rebuild_polymorphic_registry!
    CurrentScope::Current.polymorphic_registry_error = nil
    UuidUser.delete_all
  end

  def lock = CurrentScope::FullAccessLock

  def poison_registry!
    CurrentScope.config.polymorphic_class_names = { "old_token" => "User" }
    assert_raises(CurrentScope::ConfigurationError) { CurrentScope.rebuild_polymorphic_registry! }
  end

  def collide_user_token!
    CurrentScope.rebuild_polymorphic_registry!
    CurrentScope.polymorphic_registry.dup.tap do |map|
      map["User"] = Folder
      CurrentScope::PolymorphicRegistry.instance_variable_set(:@polymorphic_registry, map.freeze)
    end
    CurrentScope::Current.polymorphic_registry_error = nil
    assert_nil CurrentScope::PolymorphicRegistry.error, "this path must not latch"
  end

  def second_live_holder
    other = User.create!(name: "CoOwner")
    role = CurrentScope::Role.create!(name: "CoOwner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: other, role: role)
  end

  def orphan_assignment
    ghost = User.create!(name: "Ghost")
    assignment = CurrentScope::RoleAssignment.create!(subject: ghost, role: @owner_role)
    ghost.destroy!
    assignment.reload
  end

  def uuid_live_holder
    uuid = UuidUser.create!(id: "7f00cccc-3333-4333-8333-cccccccccccc", name: "UuidOwner")
    role = CurrentScope::Role.create!(name: "UuidOwner", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: uuid, role: role)
  end

  test "a non-full-access assignment never locks the console" do
    member = User.create!(name: "Member")
    assignment = CurrentScope::RoleAssignment.create!(subject: member, role: @member_role)
    @owner_assignment.destroy!

    refute lock.would_lock_console_by_removing_assignment?(assignment),
           "removing a member row cannot lock the console even when no FA holder remains"
  end

  test "removing the last live full-access assignment locks the console" do
    assert lock.would_lock_console_by_removing_assignment?(@owner_assignment)
  end

  test "removing one live holder while another remains does not lock" do
    second_live_holder

    refute lock.would_lock_console_by_removing_assignment?(@owner_assignment)
  end

  test "an orphan last-row can be cleaned up when no live holder remains" do
    @owner_assignment.destroy!
    orphan = orphan_assignment

    refute lock.would_lock_console_by_removing_assignment?(orphan),
           "a leftover row is not a live holder; cleanup must still be allowed"
  end

  test "an orphan does not keep the last live holder removable" do
    orphan_assignment

    assert lock.would_lock_console_by_removing_assignment?(@owner_assignment)
  end

  test "a prior registry error refuses assignment removal even when another holder remains" do
    second_live_holder
    CurrentScope::Current.polymorphic_registry_error = "claimed by both User and Folder"

    assert lock.would_lock_console_by_removing_assignment?(@owner_assignment),
           "unknown holders must refuse, not fall through to the remaining-row check"
    assert lock.registry_blind?
  end

  test "an unlatched collision refuses the last live holder and latches the cause" do
    collide_user_token!

    assert lock.would_lock_console_by_removing_assignment?(@owner_assignment)
    assert lock.registry_blind?,
           "the rescue must latch the cause so the alert can name the registry"
    assert_match(/claimed by both/, CurrentScope::Current.polymorphic_registry_error.to_s)
  end

  test "an empty assignment list does not lock the console" do
    @owner_assignment.destroy!

    refute lock.would_lock_console_by_removing_assignments?([]),
           "changing nobody cannot lock the console, even when no FA holder exists"
    refute lock.would_lock_console_by_removing_assignments?(nil)
  end

  test "clearing the last live holders locks the console" do
    assert lock.would_lock_console_by_removing_assignments?([ @owner_assignment ])
  end

  test "clearing one holder while another remains does not lock" do
    other = second_live_holder

    refute lock.would_lock_console_by_removing_assignments?([ @owner_assignment ])
    refute lock.would_lock_console_by_removing_assignments?([ other ])
  end

  test "a prior registry error refuses a bulk removal even when another holder remains" do
    second_live_holder
    CurrentScope::Current.polymorphic_registry_error = "claimed by both User and Folder"

    assert lock.would_lock_console_by_removing_assignments?([ @owner_assignment ])
    assert lock.registry_blind?
  end

  test "an unlatched collision on the affected type refuses even when a clean type remains" do
    uuid_live_holder
    collide_user_token!

    assert lock.would_lock_console_by_removing_assignments?([ @owner_assignment ]),
           "raising on the affected type must refuse before a remaining clean type is treated as enough"
    assert lock.registry_blind?
    assert_match(/claimed by both/, CurrentScope::Current.polymorphic_registry_error.to_s)
  end
end
