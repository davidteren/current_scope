require "test_helper"

# A two-model cycle, as real constants because an anonymous class cannot be
# resolved by `class_name`. Both sit on the projects table and point at each
# other by id, so CycleA#1 -> CycleB#1 -> CycleA#1 closes the loop. Named
# classes rather than fixtures because the cycle is a MISDECLARATION — no host
# should be able to reach this shape without writing it on purpose.
class CycleA < ApplicationRecord
  self.table_name = "projects"
  belongs_to :cycle_b, class_name: "CycleB", foreign_key: :id, optional: true
  current_scope_parent :cycle_b
end

class CycleB < ApplicationRecord
  self.table_name = "projects"
  belongs_to :cycle_a, class_name: "CycleA", foreign_key: :id, optional: true
  current_scope_parent :cycle_a
end

# U1 of plan 031 (#108). The declaration and the bounded walk, with no resolver
# in play. ParentChain is the ONE place that answers "what are this record's
# declared ancestors?" — everything the resolver does with the answer is pinned
# in parent_scoped_grant_test.rb and parent_scope_for_test.rb.
class ParentChainTest < ActiveSupport::TestCase
  setup do
    @requester = User.create!(name: "Requester")
    @project = Project.create!(name: "P7")
    @report = Report.create!(title: "Q3", project: @project, requested_by: @requester)
  end

  # --- R1: the declaration ---

  test "a declared chain yields the parent, nearest first" do
    assert_equal [ @project ], CurrentScope::ParentChain.ancestors_for(@report)
  end

  test "flat by default: a model that declares nothing yields no ancestors" do
    refute CurrentScope::ParentChain.declared?(Folder),
           "Folder must not opt in — this test is the flat-by-default pin"

    assert_empty CurrentScope::ParentChain.ancestors_for(Folder.create!(name: "F"))
  end

  test "a nil parent mid-chain stops the walk rather than raising — optional belongs_to is normal data" do
    orphan = Report.create!(title: "No project", project: nil, requested_by: @requester)

    assert_empty CurrentScope::ParentChain.ancestors_for(orphan)
  end

  test "an unsaved record and a Class both walk to nothing" do
    assert_empty CurrentScope::ParentChain.ancestors_for(Report.new(title: "x", requested_by: @requester))
    assert_empty CurrentScope::ParentChain.ancestors_for(Report)
  end

  # --- R1: declaration-time validation ---

  test "declaring a missing association raises and names the fix" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      Class.new(ApplicationRecord) do
        def self.name = "MissingAssoc"
        current_scope_parent :nope
      end
    end

    assert_match(/does not exist/, error.message)
    assert_match(/belongs_to/, error.message)
  end

  test "declaring a has_many raises — a scoped grant is held on ONE parent" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      Class.new(ApplicationRecord) do
        def self.name = "HasManyParent"
        self.table_name = "projects"
        has_many :reports
        current_scope_parent :reports
      end
    end

    assert_match(/must name a belongs_to/, error.message)
  end

  test "declaring a polymorphic belongs_to raises — scope_for could not build its query" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      Class.new(ApplicationRecord) do
        def self.name = "PolyParent"
        self.table_name = "reports"
        belongs_to :owner, polymorphic: true, optional: true
        current_scope_parent :owner
      end
    end

    assert_match(/polymorphic/, error.message)
  end

  test "repeated declarations are last-wins, never silently additive" do
    klass = Class.new(ApplicationRecord) do
      def self.name = "TwiceDeclared"
      self.table_name = "reports"
      belongs_to :project, optional: true
      belongs_to :requested_by, class_name: "User"
      current_scope_parent :requested_by
      current_scope_parent :project
    end

    assert_equal :project, klass.current_scope_parent_association
  end

  # --- R6: the bound ---

  test "a cycle raises and the message lists the walked chain in order" do
    node = CycleA.create!(name: "loops back to itself through CycleB")

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::ParentChain.ancestors_for(node)
    end

    assert_match(/forms a cycle/, error.message)
    assert_match(/CycleA##{node.id} -> CycleB##{node.id} -> CycleA##{node.id}/, error.message,
                 "the message must show the walked chain in order, not just name the failure")
  end

  test "a chain deeper than MAX_PARENT_DEPTH raises rather than truncating silently" do
    # A silent stop would answer "no ancestors" — i.e. no grant — for a subject
    # who holds one, which is a denial nobody can diagnose.
    root = Project.create!(name: "depth-0")
    deepest = (1..CurrentScope::ParentChain::MAX_PARENT_DEPTH + 1).reduce(root) do |parent, i|
      Project.create!(name: "depth-#{i}", parent: parent)
    end
    leaf = Report.create!(title: "too deep", project: deepest, requested_by: @requester)

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::ParentChain.ancestors_for(leaf)
    end

    assert_match(/deeper than #{CurrentScope::ParentChain::MAX_PARENT_DEPTH}/, error.message)
    assert_match(/->/, error.message)
  end

  test "a chain exactly at MAX_PARENT_DEPTH is allowed" do
    root = Project.create!(name: "at-0")
    # The Report hop counts, so build MAX - 1 project hops above it.
    deepest = (1...CurrentScope::ParentChain::MAX_PARENT_DEPTH).reduce(root) do |parent, i|
      Project.create!(name: "at-#{i}", parent: parent)
    end
    leaf = Report.create!(title: "at the ceiling", project: deepest, requested_by: @requester)

    assert_equal CurrentScope::ParentChain::MAX_PARENT_DEPTH,
                 CurrentScope::ParentChain.ancestors_for(leaf).size
  end

  test "ancestors come back nearest-first, root last" do
    grandparent = Project.create!(name: "grandparent")
    parent = Project.create!(name: "parent", parent: grandparent)
    report = Report.create!(title: "two hops", project: parent, requested_by: @requester)

    assert_equal [ parent, grandparent ], CurrentScope::ParentChain.ancestors_for(report)
  end

  test "MAX_PARENT_DEPTH is a private ceiling, not a config knob" do
    assert_equal 5, CurrentScope::ParentChain::MAX_PARENT_DEPTH
    refute CurrentScope.config.respond_to?(:max_parent_depth),
           "the depth ceiling must NOT be a host-settable knob (plan 031 KTD-7)"
  end

  # --- R7: the method-form mistake ---

  test "an instance method named current_scope_parent raises instead of being ignored" do
    klass = Class.new(ApplicationRecord) do
      def self.name = "MethodFormMistake"
      self.table_name = "reports"
      belongs_to :project, optional: true
      belongs_to :requested_by, class_name: "User"
      def current_scope_parent = project
    end
    record = klass.create!(title: "wrong form", project: @project, requested_by: @requester)

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::ParentChain.ancestors_for(record)
    end

    assert_match(/INSTANCE method/, error.message)
    assert_match(/current_scope_parent :the_association/, error.message)
  end
end
