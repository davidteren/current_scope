require "test_helper"

# U2 of plan 031 (#108). The GATE half: a scoped grant held on a declared parent
# satisfies an action on the child.
#
# The load-bearing assertions here are the two that say NO:
#   - a scoped full_access grant on a parent opens nothing on its children
#     (KTD-2 — the ancestor arm queries roles_ticking, which excludes
#     full_access; reusing roles_granting would turn one grant on a root record
#     into every permission on every descendant, #49's P0 escalation with a
#     multiplier), and
#   - the separation-of-duties veto still reads the CHILD's initiator (KTD-5),
#     which is the whole reason the chain feeds grant matching only.
class ParentScopedGrantTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @lead = User.create!(name: "Lead")
    @requester = User.create!(name: "Requester")
    @project = Project.create!(name: "P7")
    @other_project = Project.create!(name: "P8")
    @report = Report.create!(title: "Q3", project: @project, requested_by: @requester)
    @other_report = Report.create!(title: "Q4", project: @other_project, requested_by: @requester)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def scope_grant(user, role, record)
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: record)
  end

  def decide(subject, permission, record)
    @resolver.decide(subject: subject, permission: permission, record: record)
  end

  # --- R2: the feature ---

  test "a scoped grant on the parent opens the action on its child" do
    scope_grant(@lead, role("Lead", "reports#approve"), @project)

    assert_equal [ true, nil ], decide(@lead, "reports#approve", @report)
  end

  test "a grant on a SIBLING parent opens nothing on this child" do
    scope_grant(@lead, role("Lead", "reports#approve"), @other_project)

    assert_equal [ false, :no_grant ], decide(@lead, "reports#approve", @report)
  end

  test "the parent grant only opens keys its role actually ticks" do
    scope_grant(@lead, role("Lead", "reports#approve"), @project)

    assert_equal [ false, :no_grant ], decide(@lead, "reports#destroy", @report)
  end

  test "a grant two hops up reaches the child" do
    grandparent = Project.create!(name: "GP")
    @project.update!(parent: grandparent)
    scope_grant(@lead, role("Lead", "reports#approve"), grandparent)

    assert_equal [ true, nil ], decide(@lead, "reports#approve", @report)
  end

  # --- KTD-2: full_access does NOT cascade. The security crux. ---

  test "a scoped full_access grant on the parent opens NOTHING on its children" do
    scope_grant(@lead, role("Owner", full_access: true), @project)

    assert_equal [ false, :no_grant ], decide(@lead, "reports#approve", @report),
                 "full_access must not cascade down a declared chain — one grant on a " \
                 "root record would otherwise open every permission on every descendant"
  end

  test "that same scoped full_access grant still opens the parent record itself" do
    scope_grant(@lead, role("Owner", full_access: true), @project)

    assert_equal [ true, nil ], decide(@lead, "projects#update", @project),
                 "the non-cascade must not weaken a DIRECT full_access scoped grant"
  end

  # --- KTD-5: the veto reads the declared record, never an ancestor ---

  test "the SoD veto still fires on a child the parent-granted subject initiated" do
    with_sod_actions("approve") do
      scope_grant(@lead, role("Lead", "reports#approve"), @project)
      own = Report.create!(title: "mine", project: @project, requested_by: @lead)

      assert_equal [ false, :sod_veto ], decide(@lead, "reports#approve", own),
                   "the chain feeds grant matching only — the veto keeps reading the CHILD"
    end
  end

  test "the same parent grant approves a sibling report the subject did not initiate" do
    with_sod_actions("approve") do
      scope_grant(@lead, role("Lead", "reports#approve"), @project)

      assert_equal [ true, nil ], decide(@lead, "reports#approve", @report)
    end
  end

  # --- Break-glass must NOT inherit the cascade (found in review) ---

  test "a bypass_sod grant held on the PARENT does not lift the veto on a child" do
    # sod_bypassed? re-enters the resolver, so without cascade: false the #108
    # ancestor arm would satisfy the bypass permission too — lifting four-eyes on
    # every descendant off a grant never held on the record being approved.
    with_sod_actions("approve") do
      with_bypass do
        Report.sod_bypass_glass = true
        scope_grant(@lead, role("Lead", "reports#approve", "reports#bypass_sod"), @project)
        own = Report.create!(title: "mine", project: @project, requested_by: @lead)

        assert_equal [ false, :sod_veto ], decide(@lead, "reports#approve", own),
                     "break-glass held on an ancestor must NOT lift the veto — the veto's " \
                     "escape hatch is exactly what must not widen with the chain"
      end
    end
  end

  test "a bypass_sod grant held on the RECORD still lifts the veto, unchanged" do
    with_sod_actions("approve") do
      with_bypass do
        Report.sod_bypass_glass = true
        own = Report.create!(title: "mine", project: @project, requested_by: @lead)
        scope_grant(@lead, role("Lead", "reports#approve", "reports#bypass_sod"), own)

        assert_equal [ true, :sod_bypassed ], decide(@lead, "reports#approve", own),
                     "the fix must not break break-glass where it was always held"
      end
    end
  end

  # --- R1/R8: nothing changes for a model that declared nothing ---

  test "a model with no declaration is unaffected: a grant elsewhere opens nothing" do
    folder = Folder.create!(name: "F")
    other_folder = Folder.create!(name: "G")
    scope_grant(@lead, role("Lead", "folders#update"), other_folder)

    assert_equal [ false, :no_grant ], decide(@lead, "folders#update", folder)
  end

  test "a direct scoped grant on the child still works, unchanged" do
    scope_grant(@lead, role("Lead", "reports#approve"), @report)

    assert_equal [ true, nil ], decide(@lead, "reports#approve", @report)
  end

  test "a direct scoped full_access grant on the child still works, unchanged" do
    scope_grant(@lead, role("Owner", full_access: true), @report)

    assert_equal [ true, nil ], decide(@lead, "reports#approve", @report),
                 "the direct arm keeps roles_granting; only the ancestor arm narrows"
  end

  test "an orphaned child (nil parent) falls through to default-deny" do
    orphan = Report.create!(title: "no project", project: nil, requested_by: @requester)
    scope_grant(@lead, role("Lead", "reports#approve"), @project)

    assert_equal [ false, :no_grant ], decide(@lead, "reports#approve", orphan)
  end

  private

  def with_bypass
    previous = CurrentScope.config.allow_sod_bypass
    CurrentScope.config.allow_sod_bypass = true
    yield
  ensure
    CurrentScope.config.allow_sod_bypass = previous
    Report.sod_bypass_glass = false
  end

  def with_sod_actions(*actions)
    previous = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = actions
    yield
  ensure
    CurrentScope.config.sod_actions = previous
  end
end
