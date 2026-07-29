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

  def capture_warning
    messages = []
    logger = Rails.logger
    fake = Object.new
    fake.define_singleton_method(:warn) { |msg = nil, &blk| messages << (msg || blk&.call).to_s }
    fake.define_singleton_method(:respond_to_missing?) { |*| true }
    fake.define_singleton_method(:method_missing) { |*| nil }
    Rails.logger = fake
    yield
    messages.join("\n")
  ensure
    Rails.logger = logger
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

  test "declaring a SCOPED belongs_to raises — the walk would apply the scope and the query would not" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      Class.new(ApplicationRecord) do
        def self.name = "ScopedParent"
        self.table_name = "reports"
        belongs_to :project, -> { where(name: "OPEN") }, optional: true
        belongs_to :requested_by, class_name: "User"
        current_scope_parent :project
      end
    end

    assert_match(/SCOPED belongs_to/, error.message)
    assert_match(/gate and the list would disagree/, error.message)
  end

  test "declaring the chain on an STI subclass raises and names the base class" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      Class.new(Document) do
        def self.name = "StiChild"
        belongs_to :folder, optional: true
        current_scope_parent :folder
      end
    end

    assert_match(/STI subclass/, error.message)
    assert_match(/Document/, error.message)
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

  test "a data cycle truncates and warns — it does NOT raise, because rows are not a misdeclaration" do
    # Two UPDATEs on a parent_id column, no code change, must never 500 a live
    # request. Truncating denies (fail-closed); raising here used to escape
    # report mode's "never breaks a request" promise as a 500.
    node = CycleA.create!(name: "loops back to itself through CycleB")

    assert_nothing_raised do
      assert_operator CurrentScope::ParentChain.ancestors_for(node).size, :<=,
                      CurrentScope::ParentChain::MAX_PARENT_DEPTH
    end
  end

  test "a chain deeper than MAX_PARENT_DEPTH truncates to the ceiling and warns" do
    root = Project.create!(name: "depth-0")
    deepest = (1..CurrentScope::ParentChain::MAX_PARENT_DEPTH + 2).reduce(root) do |parent, i|
      Project.create!(name: "depth-#{i}", parent: parent)
    end
    leaf = Report.create!(title: "too deep", project: deepest, requested_by: @requester)

    CurrentScope::ParentChain.reset_warnings!
    logged = capture_warning { CurrentScope::ParentChain.ancestors_for(leaf) }

    assert_equal CurrentScope::ParentChain::MAX_PARENT_DEPTH,
                 CurrentScope::ParentChain.ancestors_for(leaf).size,
                 "the walk must stop AT the ceiling, not past it"
    assert_match(/stopped walking/, logged,
                 "truncation denies, so it must at least say so — a denial nobody can " \
                 "explain is its own failure")
  end

  test "a chain of EXACTLY MAX_PARENT_DEPTH does not warn — nothing was truncated" do
    # Warning here would be false, and worse: the latch is keyed [class, :depth],
    # so a false warning swallows the next genuine one for the same model.
    root = Project.create!(name: "exact-0")
    deepest = (1...CurrentScope::ParentChain::MAX_PARENT_DEPTH).reduce(root) do |parent, i|
      Project.create!(name: "exact-#{i}", parent: parent)
    end
    leaf = Report.create!(title: "exactly at the ceiling", project: deepest, requested_by: @requester)

    CurrentScope::ParentChain.reset_warnings!
    logged = capture_warning { CurrentScope::ParentChain.ancestors_for(leaf) }

    assert_equal CurrentScope::ParentChain::MAX_PARENT_DEPTH,
                 CurrentScope::ParentChain.ancestors_for(leaf).size
    refute_match(/stopped walking/, logged,
                 "a chain of exactly #{CurrentScope::ParentChain::MAX_PARENT_DEPTH} hops " \
                 "truncated nothing, so it must not warn")
  end

  test "the method-form mistake is caught on the COLLECTION path too, not only per record" do
    # reflection_for early-returned for an undeclared class, so scope_for used to
    # silently omit parent grants where the member gate raised.
    klass = Class.new(ApplicationRecord) do
      def self.name = "CollectionMethodForm"
      self.table_name = "reports"
      belongs_to :project, optional: true
      belongs_to :requested_by, class_name: "User"
      def current_scope_parent = project
    end

    # Exercised through reflection_for, which is the path scope_for actually
    # takes — not the private helper directly.
    assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::ParentChain.reflection_for(klass)
    end
  end

  test "an STI subclass that OVERRIDES the inherited association is still walked through the base" do
    # The declaration is refused on a subclass, but overriding the inherited
    # association would let the gate (instance class) and the list (base class)
    # walk different associations for the same record.
    assert_equal Report.reflect_on_association(:project).klass,
                 CurrentScope::ParentChain.reflection_for(Report).klass

    subclass = Class.new(Report) { def self.name = "OverridingReport" }

    assert_equal CurrentScope::ParentChain.reflection_for(Report).name,
                 CurrentScope::ParentChain.reflection_for(subclass).name,
                 "both must resolve through the declared BASE reflection"
  end

  test "walking a strict_loading record does not raise" do
    # A host-wide strict_loading policy would otherwise turn the gate into a 500
    # on ordinary data, via a lazy association load inside the walk.
    strict = Report.strict_loading.find(@report.id)

    assert_nothing_raised do
      assert_equal [ @project ], CurrentScope::ParentChain.ancestors_for(strict)
    end
  end

  test "truncation is fail-closed: a grant above the ceiling opens nothing" do
    root = Project.create!(name: "far-0")
    deepest = (1..CurrentScope::ParentChain::MAX_PARENT_DEPTH + 2).reduce(root) do |parent, i|
      Project.create!(name: "far-#{i}", parent: parent)
    end
    leaf = Report.create!(title: "beyond reach", project: deepest, requested_by: @requester)
    role = CurrentScope::Role.create!(name: "Far-#{rand(10**9)}")
    role.role_permissions.create!(permission_key: "reports#approve")
    CurrentScope::ScopedRoleAssignment.create!(role: role, subject: @requester, resource: root)

    assert_equal [ false, :no_grant ],
                 CurrentScope::Resolver.new.decide(subject: @requester, permission: "reports#approve", record: leaf),
                 "truncating past the ceiling must DENY, never allow"
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

  # --- Boot-time validation must survive its own autoloading ---

  # validate_declarations! runs on engine to_prepare, and resolving a
  # reflection AUTOLOADS the parent model. A parent that declares a chain of its
  # own registers itself from its class body — mutating the Set being iterated,
  # which Ruby answers with "can't add a new key into hash during iteration".
  # That is a RuntimeError out of to_prepare: a boot crash, on any host whose
  # declared chain points at another declaring model. The dummy's Report ->
  # Project is exactly that shape, and it showed up as a seed-dependent error
  # while pinning #133's boot hook — so it gets a deterministic pin here rather
  # than a flake somewhere else.
  #
  # The swap stands in for the autoload: what matters is a registration landing
  # DURING the walk, not which line performed it.
  test "a model registering itself mid-walk does not crash the boot-time validation" do
    chain = CurrentScope::ParentChain
    singleton = chain.singleton_class
    original_names = chain.instance_variable_get(:@declared_names)
    original_validate = chain.method(:validate_key!)
    chain.instance_variable_set(:@declared_names, Set.new([ "Report" ]))

    validated = []
    singleton.define_method(:validate_key!) do |klass, reflection|
      validated << klass.name
      declared_names << "Project"
      original_validate.call(klass, reflection)
    end

    assert_nothing_raised { chain.validate_declarations! }

    # And the model that registered DURING the walk is validated in the same
    # pass, not deferred: in production there is no later pass to defer to, so a
    # single snapshot would drop it silently. (#133 review — cubic)
    assert_includes validated, "Project",
                    "the walk is what loaded this model, so the walk must also check it"
  ensure
    singleton.define_method(:validate_key!, original_validate)
    singleton.send(:private, :validate_key!)
    chain.instance_variable_set(:@declared_names, original_names)
  end
end
