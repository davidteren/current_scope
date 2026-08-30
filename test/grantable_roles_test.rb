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
    [ Project, Report, Document, Invoice ].each do |klass|
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
    Project.current_scope_grantable_roles = [ "Project Lead" ]

    assignment = grant(@per_record, @project)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "cannot be granted on Project"
    assert_includes assignment.errors[:role].first, "Project Lead",
      "the message has to name what the type does accept, or the operator is guessing"
  end

  test "a declared type accepts the roles it lists" do
    Project.current_scope_grantable_roles = [ "Project Lead" ]

    assert grant(@container, @project).valid?
  end

  test "the declaration on one type says nothing about another" do
    Project.current_scope_grantable_roles = [ "Project Lead" ]

    assert grant(@per_record, @report).valid?,
      "Report declared nothing, so it still accepts anything"
  end

  test "several roles can be listed" do
    Project.current_scope_grantable_roles = [ "Project Lead", "Report Editor" ]

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
    Project.current_scope_grantable_roles = [ "Project Lead" ]

    refused = grant(@per_record, @project)
    assert_not refused.valid?, "the same pairing is now refused at the point it is written"
    assert_raises(ActiveRecord::RecordInvalid) { refused.save! }
  end

  # The check runs on every write, not on create alone: an update has to meet
  # the same rule, or the gate would be one `update` wide (#183 review).
  test "changing an existing grant to a refused role is refused too" do
    assignment = CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @container, resource: @project)
    Project.current_scope_grantable_roles = [ "Project Lead" ]

    assert_raises(ActiveRecord::RecordInvalid) { assignment.update!(role: @per_record) }
    assert_equal @container, assignment.reload.role
  end

  # A seed, a rake task and a console one-liner all write through the model, so
  # the model is where the rule has to live — the console's filtering is a
  # convenience on top of it.
  test "the rule holds for a write that never touches the console" do
    Project.current_scope_grantable_roles = [ "Project Lead" ]

    assert_raises(ActiveRecord::RecordInvalid) do
      CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @per_record, resource: @project)
    end
  end

  # #183 review — an STI subclass. CurrentScope.polymorphic_class answers with
  # the BASE class and an STI grant stores the base token, so a gate that asked
  # the token would make a subclass declaration a silent no-op while the reader,
  # the guide and this file all promise it is inherited and overridable.
  test "a declaration on an STI subclass governs grants on its records" do
    invoice = Invoice.create!(title: "INV-1")
    Invoice.current_scope_grantable_roles = [ "Project Lead" ]

    assert_not grant(@per_record, invoice).valid?,
      "the subclass declared, and the write has to meet the subclass's rule"
    assert grant(@container, invoice).valid?
  end

  test "an STI subclass with no declaration of its own follows the base class" do
    invoice = Invoice.create!(title: "INV-1")
    Document.current_scope_grantable_roles = [ "Project Lead" ]

    assert_not grant(@per_record, invoice).valid?,
      "Invoice declared nothing, so Document's rule is the one that applies"
    assert grant(@container, invoice).valid?
  end

  # An empty declaration is a LOCKDOWN, not "no restriction" (#183 review). A
  # host computing the list from config and getting an empty array must not find
  # the type wide open.
  test "an empty declaration accepts no role at all" do
    Project.current_scope_grantable_roles = []

    assignment = grant(@container, @project)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "accepts no scoped roles at all"
  end

  # And its opposite number: nil is NO declaration, so a host reading its list
  # from config still gets the documented default when the key is missing
  # (#183 review). Same value in, same meaning out.
  test "assigning nil leaves the type undeclared rather than locking it down" do
    Project.current_scope_grantable_roles = nil

    assert_nil Project.current_scope_grantable_roles
    assert grant(@per_record, @project).valid?,
      "a missing config key must not lock the type down"
  end

  # A Role RECORD is a natural thing to reach for, and to_s on one yields an
  # inspect string that matches nothing — a silent lockdown (#183 review).
  test "a Role record may be declared, not only its name" do
    Project.current_scope_grantable_roles = [ @container ]

    assert_equal [ "Project Lead" ], Project.current_scope_grantable_roles
    assert grant(@container, @project).valid?
  end

  # `%w[Lead] + [ENV["EXTRA"]]` with the variable unset would otherwise store
  # "", which matches no role and locks the type silently (#183 review).
  test "a blank entry is dropped rather than stored as a role no one has" do
    Project.current_scope_grantable_roles = [ "Project Lead", nil, "" ]

    assert_equal [ "Project Lead" ], Project.current_scope_grantable_roles
    assert grant(@container, @project).valid?
  end

  test "a subclass inherits its parent's declaration until it states its own" do
    Project.current_scope_grantable_roles = [ "Project Lead" ]
    subclass = Class.new(Project) { def self.name = "SpecialProject" }

    assert_equal [ "Project Lead" ], subclass.current_scope_grantable_roles

    subclass.current_scope_grantable_roles = [ "Special Lead" ]
    assert_equal [ "Special Lead" ], subclass.current_scope_grantable_roles
    assert_equal [ "Project Lead" ], Project.current_scope_grantable_roles,
      "and stating its own must not rewrite the parent's"
  end
end
