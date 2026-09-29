require "test_helper"

# Direct pins for the assignment-removal guards added in #218. Integration
# tests go through HTTP and miss the early-return mutants Mutineer found:
# a non-full-access row, an empty list, a leftover orphan as the last row,
# and registry_blind? while another live holder remains.
class FullAccessLockAssignmentTest < ActiveSupport::TestCase
  # Records RoleAssignment lock batches. SQLite drops FOR UPDATE, so the SQL
  # text cannot tell a lock from a later read of the same ids.
  module LockProbe
    def self.batches
      Thread.current[:full_access_assignment_lock_batches]
    end

    def self.record
      Thread.current[:full_access_assignment_lock_batches] = []
      yield
      Thread.current[:full_access_assignment_lock_batches]
    ensure
      Thread.current[:full_access_assignment_lock_batches] = nil
    end

    def self.ids_from(relation)
      relation.where_clause.send(:predicates).flat_map { |node| LockProbe.ids_from_predicate(node) }
    end

    def self.ids_from_predicate(node)
      node = node.expr if node.is_a?(Arel::Nodes::Grouping)
      if node.is_a?(Arel::Nodes::And)
        return node.children.flat_map { |child| LockProbe.ids_from_predicate(child) }
      end
      return [] unless node.respond_to?(:left) && node.left.respond_to?(:name)
      return [] unless node.left.name.to_s == "id"

      if node.is_a?(Arel::Nodes::HomogeneousIn)
        Array(node.values)
      elsif node.respond_to?(:right)
        LockProbe.unwrap_ids(node.right)
      else
        []
      end
    end

    def self.unwrap_ids(value)
      if value.is_a?(Array)
        value.map { |item| LockProbe.unwrap_ids(item) }
      elsif value.respond_to?(:value_before_type_cast)
        value.value_before_type_cast
      else
        value
      end
    end

    def lock(*)
      relation = super
      batches = LockProbe.batches
      return relation unless batches && relation.lock_value
      return relation unless relation.klass == CurrentScope::RoleAssignment

      ids = LockProbe.ids_from(relation)
      batches << ids unless ids.empty?
      relation
    end
  end
  ActiveRecord::Relation.prepend(LockProbe) unless ActiveRecord::Relation.ancestors.include?(LockProbe)
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

  def unresolvable_assignment(role)
    ghost = User.create!(name: "Ghost #{role.name}")
    assignment = CurrentScope::RoleAssignment.create!(subject: ghost, role: role)
    ghost.destroy!
    assignment.reload
  end

  def with_assignment_page_size(size)
    singleton = lock.singleton_class
    singleton.alias_method(:__assignment_lock_page_size_original, :assignment_lock_page_size)
    singleton.define_method(:assignment_lock_page_size) { size }
    yield
  ensure
    singleton.alias_method(:assignment_lock_page_size, :__assignment_lock_page_size_original)
    singleton.remove_method(:__assignment_lock_page_size_original)
  end

  def assignment_locks(&block)
    LockProbe.record(&block)
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

  test "the assignment lock page size is a fixed bound" do
    assert_equal 100, lock::ASSIGNMENT_LOCK_PAGE_SIZE
    assert_equal 100, lock.assignment_lock_page_size
  end

  test "an inert first planned page does not count as the holder" do
    promoted = CurrentScope::Role.create!(name: "Promoted")
    inert = unresolvable_assignment(promoted)
    live = CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Pat"), role: promoted)
    assert inert.id < live.id

    batches = with_assignment_page_size(1) do
      assignment_locks do
        refute lock.would_lose_held_full_access?([ "Promoted" ]),
               "the live holder on the next page keeps the console open"
      end
    end

    assert_equal [ [ @owner_assignment.id ], [ inert.id ], [ live.id ] ], batches,
                 "page size 1 must lock the inert row and still lock the later live holder"
  end

  test "a blank planned subject is not a holder" do
    promoted = CurrentScope::Role.create!(name: "Promoted")
    blank = CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Blank"), role: promoted)
    blank.update_columns(subject_type: "", subject_id: "")
    live = CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Pat"), role: promoted)

    batches = with_assignment_page_size(1) do
      assignment_locks do
        refute lock.would_lose_held_full_access?([ "Promoted" ])
      end
    end

    assert_equal [ [ @owner_assignment.id ], [ blank.id ], [ live.id ] ], batches
  end

  test "a planned holder with a lower id than the current holder keeps the console open" do
    @owner_assignment.destroy!
    promoted = CurrentScope::Role.create!(name: "Promoted")
    planned = CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Pat"), role: promoted)
    current = CurrentScope::RoleAssignment.create!(subject: @owner, role: @owner_role)
    assert planned.id < current.id

    batches = with_assignment_page_size(1) do
      assignment_locks do
        refute lock.would_lose_held_full_access?([ "Promoted" ]),
               "the lower planned id is on its own keyset and still counts"
      end
    end

    assert_equal [ [ current.id ], [ planned.id ] ], batches,
                 "current full-access ids are locked before the planned keyset"
  end

  test "a planned holder that is already full access is locked once and still counts" do
    batches = with_assignment_page_size(1) do
      assignment_locks do
        refute lock.would_lose_held_full_access?([ "Owner" ]),
               "the row was already locked, and the liveness rule must still see it"
      end
    end

    assert_equal [ [ @owner_assignment.id ] ], batches
  end

  test "inert planned pages still lose the last live holder" do
    promoted = CurrentScope::Role.create!(name: "Promoted")
    first = unresolvable_assignment(promoted)
    second = unresolvable_assignment(promoted)

    batches = with_assignment_page_size(1) do
      assignment_locks do
        assert lock.would_lose_held_full_access?([ "Promoted" ]),
               "no planned name has a live holder, and one live holder exists today"
      end
    end

    assert_equal [ [ @owner_assignment.id ], [ first.id ], [ second.id ] ], batches,
                 "every planned page is locked before the would-lose answer"
  end

  test "no current live holder still allows a document whose planned rows are inert" do
    @owner_assignment.destroy!
    promoted = CurrentScope::Role.create!(name: "Promoted")
    inert = unresolvable_assignment(promoted)

    batches = with_assignment_page_size(1) do
      assignment_locks do
        refute lock.would_lose_held_full_access?([ "Promoted" ]),
               "a missing planned holder refuses only when a current live holder exists"
      end
    end

    assert_equal [ [ inert.id ] ], batches
  end

  test "a later unread planned page does not undo a locked live holder" do
    @owner_assignment.destroy!
    promoted = CurrentScope::Role.create!(name: "Promoted")
    live_user = UuidUser.create!(id: "7f00cccc-3333-4333-8333-ccccccc00001", name: "Live")
    live = CurrentScope::RoleAssignment.create!(subject: live_user, role: promoted)
    bad = CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Later"), role: promoted)
    current_user = UuidUser.create!(id: "7f00cccc-3333-4333-8333-ccccccc00002", name: "Current")
    current_role = CurrentScope::Role.create!(name: "UuidOwner", full_access: true)
    current = CurrentScope::RoleAssignment.create!(subject: current_user, role: current_role)
    assert live.id < bad.id
    assert bad.id < current.id
    collide_user_token!

    batches = with_assignment_page_size(1) do
      assignment_locks do
        refute lock.would_lose_held_full_access?([ "Promoted" ]),
               "the locked live holder stands, and the later colliding page is not read"
      end
    end

    assert_equal [ [ current.id ], [ live.id ] ], batches
    assert_nil CurrentScope::Current.polymorphic_registry_error
  end

  test "a blind registry refuses the would-lose question" do
    poison_registry!

    assert lock.would_lose_held_full_access?([ "Owner" ]),
           "unknown holders must refuse the apply question, not only assignment removal"
    assert lock.registry_blind?
  end

  test "a registry collision on the would-lose question refuses and latches the cause" do
    collide_user_token!

    assert lock.would_lose_held_full_access?([ "Owner" ])
    assert lock.registry_blind?,
           "the walker's rescue must latch the cause instead of raising"
    assert_match(/claimed by both/, CurrentScope::Current.polymorphic_registry_error.to_s)
  end

  test "the console lock pages every current full-access id and skips other rows" do
    other = second_live_holder
    member = CurrentScope::RoleAssignment.create!(subject: User.create!(name: "Member"), role: @member_role)
    low, high = [ @owner_assignment.id, other.id ].minmax

    batches = with_assignment_page_size(1) do
      assignment_locks { lock.lock_console_state! }
    end

    assert_equal [ [ low ], [ high ] ], batches
    refute batches.flatten.include?(member.id), "a non-full-access row is not part of the console lock"
  end
end
