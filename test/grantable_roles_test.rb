require "test_helper"

# #183. A role's permission bundle is written for one SHAPE of record. With
# parent-chain resolution a grant held on a CONTAINER resolves for every record
# inside it, so pairing a per-record role with a container type hands the
# subject that per-record surface across the whole container — an assignment
# nobody designed, made by one wrong pick in a dropdown.
#
# The declaration is opt-in: a type that says nothing accepts every role, which
# is what every existing host has today.
class GrantableRolesTest < ActiveSupport::TestCase
  setup do
    @alice = User.create!(name: "Alice")
    @project = Project.create!(name: "Q3")
    @report = Report.create!(title: "Q3 report", project: @project, requested_by: @alice)
    @per_record = role("Report Editor", "reports#show")
    @container = role("Project Lead", "projects#show")
  end

  teardown do
    [ Project, Report ].each do |klass|
      next unless klass.instance_variable_defined?(:@current_scope_grantable_roles)

      klass.send(:remove_instance_variable, :@current_scope_grantable_roles)
    end
  end

  def role(name, *keys)
    r = CurrentScope::Role.create!(name: name)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def grant(role, resource)
    CurrentScope::ScopedRoleAssignment.new(subject: @alice, role: role, resource: resource)
  end

  test "a type that declares nothing accepts every role, exactly as before" do
    assert grant(@per_record, @project).valid?,
      "no declaration must change nothing: this is what every existing host has"
    assert grant(@container, @report).valid?
  end

  test "a declared type refuses a role it does not list" do
    Project.current_scope_grantable_roles "Project Lead"

    assignment = grant(@per_record, @project)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "cannot be granted on Project"
    assert_includes assignment.errors[:role].first, "Project Lead",
      "the message has to name what the type does accept, or the operator is guessing"
  end

  test "a declared type accepts the roles it lists" do
    Project.current_scope_grantable_roles "Project Lead"

    assert grant(@container, @project).valid?
  end

  test "the declaration on one type says nothing about another" do
    Project.current_scope_grantable_roles "Project Lead"

    assert grant(@per_record, @report).valid?,
      "Report declared nothing, so it still accepts anything"
  end

  test "several roles can be listed" do
    Project.current_scope_grantable_roles "Project Lead", "Report Editor"

    assert grant(@per_record, @project).valid?
    assert grant(@container, @project).valid?
  end

  # THE SCENARIO THE ISSUE DESCRIBES, end to end. Without the declaration the
  # per-record role granted on the container reaches every record inside it.
  test "the declaration is what stops a per-record role reaching a whole container" do
    resolver = CurrentScope::Resolver.new

    # Before: nothing objects, and the grant opens the child through the chain.
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @per_record, resource: @project)
    assert resolver.allow?(subject: @alice, permission: "reports#show", record: @report),
      "this is the widening: a Report surface, granted once on the Project"

    CurrentScope::ScopedRoleAssignment.delete_all
    Project.current_scope_grantable_roles "Project Lead"

    refused = grant(@per_record, @project)
    assert_not refused.valid?, "the same pairing is now refused at the point it is written"
    assert_raises(ActiveRecord::RecordInvalid) { refused.save! }
  end

  # A seed, a rake task and a console one-liner all write through the model, so
  # the model is where the rule has to live — the console's filtering is a
  # convenience on top of it.
  test "the rule holds for a write that never touches the console" do
    Project.current_scope_grantable_roles "Project Lead"

    assert_raises(ActiveRecord::RecordInvalid) do
      CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @per_record, resource: @project)
    end
  end

  # An empty declaration is a LOCKDOWN, not "no restriction" (#183 review). A
  # host computing the list from config and getting an empty array must not find
  # the type wide open.
  test "an empty declaration accepts no role at all" do
    Project.current_scope_grantable_roles []

    assignment = grant(@container, @project)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "accepts no scoped roles at all"
  end

  # And the caveat that goes with it: a splatted empty array cannot be told
  # apart from the reader, so the documented form is to pass the array.
  test "the declaration must be passed as an array, not splatted, when it is computed" do
    computed = []
    Project.current_scope_grantable_roles(computed)

    assert_equal [], Project.current_scope_grantable_roles,
      "passing the array declares the lockdown"
  end

  test "a subclass inherits its parent's declaration until it states its own" do
    Project.current_scope_grantable_roles "Project Lead"
    subclass = Class.new(Project) { def self.name = "SpecialProject" }

    assert_equal [ "Project Lead" ], subclass.current_scope_grantable_roles

    subclass.current_scope_grantable_roles "Special Lead"
    assert_equal [ "Special Lead" ], subclass.current_scope_grantable_roles
    assert_equal [ "Project Lead" ], Project.current_scope_grantable_roles,
      "and stating its own must not rewrite the parent's"
  end
end
