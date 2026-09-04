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
    declare_grantable_roles(Project, [ "Project Lead" ])

    assignment = grant(@per_record, @project)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "cannot be granted on Project"
    assert_includes assignment.errors[:role].first, "Project Lead",
      "the message has to name what the type does accept, or the operator is guessing"
  end

  test "a declared type accepts the roles it lists" do
    declare_grantable_roles(Project, [ "Project Lead" ])

    assert grant(@container, @project).valid?
  end

  test "the declaration on one type says nothing about another" do
    declare_grantable_roles(Project, [ "Project Lead" ])

    assert grant(@per_record, @report).valid?,
      "Report declared nothing, so it still accepts anything"
  end

  test "several roles can be listed" do
    declare_grantable_roles(Project, [ "Project Lead", "Report Editor" ])

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
    declare_grantable_roles(Project, [ "Project Lead" ])

    refused = grant(@per_record, @project)
    assert_not refused.valid?, "the same pairing is now refused at the point it is written"
    assert_raises(ActiveRecord::RecordInvalid) { refused.save! }
  end

  # The check runs on every write, not on create alone: an update has to meet
  # the same rule, or the gate would be one `update` wide (#183).
  test "changing an existing grant to a refused role is refused too" do
    assignment = CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @container, resource: @project)
    declare_grantable_roles(Project, [ "Project Lead" ])

    assert_raises(ActiveRecord::RecordInvalid) { assignment.update!(role: @per_record) }
    assert_equal @container, assignment.reload.role
  end

  # The setter takes a name or a Role, so the predicate does too — asking about
  # a role by the name you declared it with is the first thing to try, and it
  # raised NoMethodError (#183).
  test "the predicate answers about a role NAME, not only a Role record" do
    declare_grantable_roles(Project, [ "Project Lead" ])

    assert Project.current_scope_grants_role?("Project Lead")
    assert_not Project.current_scope_grants_role?("Report Editor")
    assert_raises(ArgumentError, "a nil role is a caller error, not a refusal") do
      Project.current_scope_grants_role?(nil)
    end
  end

  # A host may answer the predicate itself and hold no list — the message must
  # then say the type refused THIS role, not that it accepts none (#183).
  test "a type that computes its own answer is refused without being called empty" do
    Project.define_singleton_method(:current_scope_grants_role?) { |_role| false }

    assignment = grant(@container, @project)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "does not accept this one"
    assert_not_includes assignment.errors[:role].first, "accepts no scoped roles at all"
  ensure
    Project.singleton_class.send(:remove_method, :current_scope_grants_role?)
  end

  # The wider indexed fetch asks this, and so may a host: does a declaration
  # anywhere in this hierarchy exist to filter by?
  test "declares_roles? sees a declaration on the class or on a loaded subclass" do
    assert_not Document.current_scope_declares_roles_anywhere?

    declare_grantable_roles(SpecialInvoice, [ "Project Lead" ])
    assert Document.current_scope_declares_roles_anywhere?, "a loaded subclass declared"
    assert SpecialInvoice.current_scope_declares_roles_anywhere?
  end

  # The trade the whole design rests on: declarations name roles, and role ids
  # cannot be written in a model file. So a rename stops the declaration
  # matching, and a new role reusing the name inherits its acceptance. The guide
  # says so; nothing pinned it (#183).
  test "a declaration follows the NAME, so a rename stops matching and a reuse inherits" do
    declare_grantable_roles(Project, [ "Project Lead" ])
    assert grant(@container, @project).valid?

    @container.update!(name: "Project Owner")
    assert_not grant(@container, @project).valid?, "the renamed role is no longer the one named"

    reused = CurrentScope::Role.create!(name: "Project Lead")
    assert grant(reused, @project).valid?, "and a new role reusing the name inherits the acceptance"
  end

  # A subclass assigning nil has NO declaration of its own, so it inherits the
  # parent's — a lockdown included (docs/guides/checking-permissions.md).
  test "nil on a subclass under a locked-down base inherits the lockdown" do
    invoice = Invoice.create!(title: "INV-1")
    declare_grantable_roles(Document, [])
    declare_grantable_roles(Invoice, nil)

    assignment = grant(@container, invoice)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "accepts no scoped roles at all"
  end

  # The module exists apart from Scopeable so a type can state its rule without
  # becoming browsable in the console — the guide's stated reason for the split.
  test "including the module alone does not register the type in the picker" do
    assert_includes Project.included_modules, CurrentScope::GrantableRoles
    assert_not_includes CurrentScope.scopeable_resources, Project
  end

  # The other half of "adding a declaration rewrites no existing grant": the row
  # already written keeps RESOLVING. The gate is a validation, and the resolver
  # never asks it — `bin/rails current_scope:report` is what names those rows.
  test "a grant written before the declaration keeps resolving afterwards" do
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @per_record, resource: @project)
    resolver = CurrentScope::Resolver.new
    assert resolver.allow?(subject: @alice, permission: "reports#show", record: @report)

    declare_grantable_roles(Project, [ "Project Lead" ])

    assert resolver.allow?(subject: @alice, permission: "reports#show", record: @report),
      "the declaration judges WRITES; the row that predates it is untouched and still opens the child"
  end

  # The lockdown answer must not depend on what this process happens to have
  # loaded: a declaring subclass nothing has referenced would otherwise read as
  # "no subclass declares", and the console would state a lockdown that is false
  # while hiding the search that reaches those records (#183).
  test "the lockdown answer comes from the rows, not from the loaded classes" do
    declare_grantable_roles(Document, [])
    assert Document.current_scope_locked_down_everywhere?, "an empty table cannot hold a grantable record"

    Receipt.create!(title: "RCT-1") # inherits the empty declaration
    assert Document.current_scope_locked_down_everywhere?

    Invoice.create!(title: "INV-1")
    declare_grantable_roles(Invoice, [ "Project Lead" ])

    assert_not Document.current_scope_locked_down_everywhere?,
      "a row of a declaring class is in the table, whatever the class registry has seen"
  end

  # What this pins is the direction the answer fails in, not a resolution
  # mechanism. `current_scope_locked_down_everywhere?` builds its locked set from
  # LOADED classes and asks whether any row names something outside it, so a type
  # it cannot account for — unloaded, renamed, or never a class at all — falls
  # outside and counts against the lockdown. That is the safe direction: an
  # unrecognised row means "cannot claim a lockdown", never "locked down" (#183).
  test "a type the locked set cannot account for is not evidence of a lockdown" do
    declare_grantable_roles(Document, [])
    Document.insert_all([ { title: "X", type: "NoSuchClass", created_at: Time.current,
                            updated_at: Time.current } ])

    assert_not Document.current_scope_locked_down_everywhere?,
      "a row whose class cannot be resolved is not evidence of a lockdown"
  end

  # A lockdown answer must not aggregate the table to choose a sentence: it asks
  # whether ANY row names a class outside the locked set, which stops at the
  # first one (#183).
  test "the lockdown answer stops at the first row that disproves it" do
    declare_grantable_roles(Document, [])
    now = Time.current
    Document.insert_all(Array.new(50) { |i| { title: "R-#{i}", type: "Receipt", created_at: now, updated_at: now } })
    Invoice.create!(title: "INV-1")
    declare_grantable_roles(Invoice, [ "Project Lead" ])

    sql = []
    watcher = ->(*, payload) { sql << payload[:sql] if payload[:sql].to_s.include?("documents") }
    ActiveSupport::Notifications.subscribed(watcher, "sql.active_record") do
      assert_not Document.current_scope_locked_down_everywhere?
    end

    assert sql.any? { |q| q.include?("LIMIT") && !q.include?("DISTINCT") },
      "an EXISTS, not an aggregate over every row: #{sql.inspect}"
  end

  # The module registers its own includers, which is a SUPERSET of the picker's
  # list: a container model can take the rule without becoming browsable, and
  # that is the shape #183 was opened for (#183).
  test "a type that takes the rule without the picker is still known to declare" do
    assert_includes CurrentScope.grantable_roles_resources, Project
    assert_not_includes CurrentScope.scopeable_resources, Project
  end

  # A seed, a rake task and a console one-liner all write through the model, so
  # the model is where the rule has to live — the console's filtering is a
  # convenience on top of it.
  test "the rule holds for a write that never touches the console" do
    declare_grantable_roles(Project, [ "Project Lead" ])

    assert_raises(ActiveRecord::RecordInvalid) do
      CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @per_record, resource: @project)
    end
  end

  # #183 — an STI subclass. CurrentScope.polymorphic_class answers with
  # the BASE class and an STI grant stores the base token, so a gate that asked
  # the token would make a subclass declaration a silent no-op while the reader,
  # the guide and this file all promise it is inherited and overridable.
  test "a declaration on an STI subclass governs grants on its records" do
    invoice = Invoice.create!(title: "INV-1")
    declare_grantable_roles(Invoice, [ "Project Lead" ])

    assert_not grant(@per_record, invoice).valid?,
      "the subclass declared, and the write has to meet the subclass's rule"
    assert grant(@container, invoice).valid?
  end

  test "an STI subclass with no declaration of its own follows the base class" do
    invoice = Invoice.create!(title: "INV-1")
    declare_grantable_roles(Document, [ "Project Lead" ])

    assert_not grant(@per_record, invoice).valid?,
      "Invoice declared nothing, so Document's rule is the one that applies"
    assert grant(@container, invoice).valid?
  end

  # An empty declaration is a LOCKDOWN, not "no restriction" (#183). A
  # host computing the list from config and getting an empty array must not find
  # the type wide open.
  # The record answers for itself while it is there. Once it is gone, the stored
  # token is all that is left, and that token names the BASE class — so an
  # orphaned STI grant meets the base's declaration, not the subclass's. The
  # guide says so; this pins it, because a resolver that answered nil here
  # instead would skip the gate and open every orphaned grant (#183).
  test "an orphaned STI grant is judged by the base class" do
    special = SpecialInvoice.create!(title: "SI-1")
    assignment = CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: @container, resource: special)
    declare_grantable_roles(Document, [])
    declare_grantable_roles(SpecialInvoice, [ "Project Lead" ])

    assert assignment.valid?, "the live record is a SpecialInvoice, which accepts this role"

    special.delete # leaves the grant pointing at a row that is no longer there
    assignment.reload

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "cannot be granted on Document"
  end

  test "an empty declaration accepts no role at all" do
    declare_grantable_roles(Project, [])

    assignment = grant(@container, @project)

    assert_not assignment.valid?
    assert_includes assignment.errors[:role].first, "accepts no scoped roles at all"
  end

  # And its opposite number: nil is NO declaration, so a host reading its list
  # from config still gets the documented default when the key is missing
  # (#183). Same value in, same meaning out.
  test "assigning nil leaves the type undeclared rather than locking it down" do
    declare_grantable_roles(Project, nil)

    assert_nil Project.current_scope_grantable_roles
    assert grant(@per_record, @project).valid?,
      "a missing config key must not lock the type down"
  end

  # A Role RECORD is a natural thing to reach for, and to_s on one yields an
  # inspect string that matches nothing — a silent lockdown (#183).
  test "a Role record may be declared, not only its name" do
    declare_grantable_roles(Project, [ @container ])

    assert_equal [ "Project Lead" ], Project.current_scope_grantable_roles
    assert grant(@container, @project).valid?
  end

  # `%w[Lead] + [ENV["EXTRA"]]` with the variable unset would otherwise store
  # "", which matches no role and locks the type silently (#183).
  test "a blank entry is dropped rather than stored as a role no one has" do
    declare_grantable_roles(Project, [ "Project Lead", nil, "" ])

    assert_equal [ "Project Lead" ], Project.current_scope_grantable_roles
    assert grant(@container, @project).valid?
  end

  test "a subclass inherits its parent's declaration until it states its own" do
    declare_grantable_roles(Project, [ "Project Lead" ])
    subclass = Class.new(Project) { def self.name = "SpecialProject" }

    assert_equal [ "Project Lead" ], subclass.current_scope_grantable_roles

    declare_grantable_roles(subclass, [ "Special Lead" ])
    assert_equal [ "Special Lead" ], subclass.current_scope_grantable_roles
    assert_equal [ "Project Lead" ], Project.current_scope_grantable_roles,
      "and stating its own must not rewrite the parent's"
  end
end
