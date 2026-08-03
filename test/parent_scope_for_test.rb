require "test_helper"

# U3 of plan 031 (#108). The LIST half — which is also a gate.
#
# scope_for is not list cosmetics: record_less_scoped_grant?'s read arm takes
# .exists? of this relation (resolver.rb), so for every action in
# config.collection_read_actions the scope_for query IS the authorization
# decision. That is why the ancestor arm here uses roles_ticking, matching
# scoped_grant?, and why "gate and list agree" is asserted through the gate
# rather than only through scope_for.
class ParentScopeForTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @lead = User.create!(name: "Lead")
    @requester = User.create!(name: "Requester")
    @project = Project.create!(name: "P7")
    @other_project = Project.create!(name: "P8")
    @mine = Report.create!(title: "mine", project: @project, requested_by: @requester)
    @also_mine = Report.create!(title: "also mine", project: @project, requested_by: @requester)
    @theirs = Report.create!(title: "theirs", project: @other_project, requested_by: @requester)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def scope_grant(user, role, record)
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: record)
  end

  def listed(permission = "reports#index")
    @resolver.scope_for(subject: @lead, model: Report, permission: permission).pluck(:title).sort
  end

  # --- R5: the list follows the gate ---

  test "a parent-scoped grant lists that parent's children and no others" do
    scope_grant(@lead, role("Lead", "reports#index"), @project)

    assert_equal [ "also mine", "mine" ], listed
  end

  test "a grant two hops up lists the grandchildren" do
    grandparent = Project.create!(name: "GP")
    @project.update!(parent: grandparent)
    scope_grant(@lead, role("Lead", "reports#index"), grandparent)

    assert_equal [ "also mine", "mine" ], listed
  end

  test "a direct grant on the child and a parent grant union rather than replace" do
    scope_grant(@lead, role("Lead", "reports#index"), @project)
    scope_grant(@lead, role("Other", "reports#index"), @theirs)

    assert_equal [ "also mine", "mine", "theirs" ], listed
  end

  test "no declaration means no ancestor arm: an unopted model lists only direct grants" do
    keep = Folder.create!(name: "keep")
    Folder.create!(name: "drop")
    scope_grant(@lead, role("Lead", "folders#index"), keep)

    assert_equal [ "keep" ],
                 @resolver.scope_for(subject: @lead, model: Folder, permission: "folders#index").pluck(:name)
  end

  # --- KTD-2: full_access does not cascade here either ---

  test "a scoped full_access grant on the parent lists NOTHING of its children" do
    scope_grant(@lead, role("Owner", full_access: true), @project)

    assert_empty listed,
                 "the ancestor arm uses roles_ticking; a cascading full_access here would " \
                 "be the same escalation as in the gate, one query later"
  end

  # Same gap as the gate side (#148): the test above never runs the exclusion,
  # because its Owner role ticks nothing and roles_ticking drops it on the
  # permission_key filter first.
  test "a scoped full_access grant that ALSO ticks the key lists nothing of its children" do
    scope_grant(@lead, role("Owner", "reports#index", full_access: true), @project)

    assert_empty listed,
                 "roles_ticking must exclude full_access roles even when they tick the " \
                 "key; otherwise one scoped grant on a parent cascades to every child"

    # POSITIVE CONTROL, per R8 below. Asserted second so it needs no teardown:
    # `assert_empty` above also passes when the ancestor arm is dead, since
    # "excluded" and "the chain never resolved" are indistinguishable from here.
    scope_grant(@lead, role("Lead", "reports#index"), @project)

    assert_includes listed, "mine",
                    "control: an ordinary ticking role on the parent MUST list the child"
  end

  test "a direct scoped full_access grant on a child still lists that child" do
    scope_grant(@lead, role("Owner", full_access: true), @mine)

    assert_equal [ "mine" ], listed,
                 "the direct arm keeps roles_granting (#65) — only the ancestor arm narrows"
  end

  # --- The invariant that made this a gate: agreement, asserted THROUGH the gate ---

  test "gate and list agree: the record-less collection gate opens exactly when the list is non-empty" do
    scope_grant(@lead, role("Lead", "reports#index"), @project)

    # collection_read_actions routes the record-less gate through scope_for.
    assert_includes CurrentScope.config.collection_read_actions, "index"
    allowed, = @resolver.decide(subject: @lead, permission: "reports#index", record: nil, model: Report)

    assert allowed, "the gate must open when the parent-scoped list has rows"
    refute_empty listed
  end

  test "gate and list agree when the parent grant is for a DIFFERENT key" do
    scope_grant(@lead, role("Lead", "reports#approve"), @project)

    allowed, = @resolver.decide(subject: @lead, permission: "reports#index", record: nil, model: Report)

    refute allowed, "a grant ticking approve must not open the index gate"
    assert_empty listed
  end

  # --- R8: the pins that must not move ---

  test "a parent grant opens nothing once the parent is destroyed" do
    # The POSITIVE CONTROL is the point. Without it this test passed with the
    # ancestor arm entirely deleted: Project has `has_many :reports, dependent:
    # :nullify`, so destroying the parent clears project_id before the assertion
    # runs, and the arm matched nothing for a reason unrelated to liveness.
    scope_grant(@lead, role("Lead", "reports#index"), @project)

    assert_includes listed, "mine", "control: the parent grant must list the child BEFORE the destroy"

    @project.destroy

    assert_empty listed, "and nothing after it"
  end

  test "the gate agrees with the list, record by record" do
    # The pairing that catches gate/list drift. Asserting the record-less gate
    # against list emptiness (above) does not: it compares a boolean to a count,
    # so a per-record disagreement hides inside a non-empty list.
    scope_grant(@lead, role("Lead", "reports#index"), @project)

    listed_ids = @resolver.scope_for(subject: @lead, model: Report, permission: "reports#index").pluck(:id)

    Report.find_each do |report|
      allowed, = @resolver.decide(subject: @lead, permission: "reports#index", record: report)
      assert_equal listed_ids.include?(report.id), allowed,
                   "scope_for and decide disagree about Report##{report.id} " \
                   "(#{report.title}) — listed=#{listed_ids.include?(report.id)} allowed=#{allowed}"
    end
  end

  test "the gate agrees with the list past the depth ceiling, where the two walks used to diverge" do
    # The record walk truncates and the class walk truncates at the SAME ceiling.
    # An earlier cut raised on one side and broke silently on the other, so a
    # deep tree 500ed the member gate while the list happily answered.
    root = Project.create!(name: "deep-0")
    deepest = (1..CurrentScope::ParentChain::MAX_PARENT_DEPTH + 2).reduce(root) do |parent, i|
      Project.create!(name: "deep-#{i}", parent: parent)
    end
    far = Report.create!(title: "far", project: deepest, requested_by: @requester)
    scope_grant(@lead, role("Lead", "reports#index"), root)

    listed_ids = @resolver.scope_for(subject: @lead, model: Report, permission: "reports#index").pluck(:id)
    allowed, = @resolver.decide(subject: @lead, permission: "reports#index", record: far)

    assert_equal listed_ids.include?(far.id), allowed,
                 "past the ceiling the gate and the list must still agree"
    refute allowed, "and both must DENY — truncation is fail-closed"
  end
end
