require "test_helper"

# The record-less half of the per-record feature: a collection gate (#index and
# friends) reaches the resolver with `record: nil`, and a class-form check
# (allowed_to?(:index, Report)) reaches it with a Class. Neither can carry a
# scoped grant, so a scoped-only subject used to be turned away from the very
# list scope_for exists to narrow — and the org-wide grant that got them past
# the gate made scope_for return every record. This suite pins the fix: a
# record-less target is allowed when the subject holds ANY scoped grant whose
# role ticks the key, while every persisted-record decision stays byte-for-byte
# unchanged (the load-bearing assertions below).
class CollectionScopeGateTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
    @other = Report.create!(title: "Q4", requested_by: @bob)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  def assign(user, role) = CurrentScope::RoleAssignment.create!(subject: user, role: role)

  def scope_grant(user, role, record)
    CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: record)
  end

  # --- R1/R3: a scoped grant opens the record-less gate ---

  test "a scoped grant whose role ticks the key opens a nil-record collection gate" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil)
    assert allowed, "a scoped-only subject must reach the list scope_for exists to narrow"
    assert_nil reason, "an ordinary grant carries no reason — it is not an audited exception"
  end

  test "a scoped grant whose role ticks the key opens a class-form check" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: Report),
      "the view helper and the gate must never disagree"
  end

  test "a scoped full_access role opens the record-less gate for any key" do
    scope_grant(@alice, role("RecordOwner", full_access: true), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
  end

  # --- R4: still fail-closed ---

  test "a scoped role that does not tick the key leaves the record-less gate shut" do
    scope_grant(@alice, role("Viewer", "reports#show"), @report) # no reports#index

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil)
    assert_not allowed
    assert_equal :no_grant, reason
  end

  test "a scoped role that does not tick the key leaves the class-form check shut" do
    scope_grant(@alice, role("Viewer", "reports#show"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)
  end

  test "no grants at all still denies a record-less target (fail closed)" do
    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index", record: nil)
    assert_not allowed
    assert_equal :no_grant, reason
  end

  test "a nil subject still denies a record-less target (fail closed)" do
    assert_not @resolver.allow?(subject: nil, permission: "reports#index", record: nil)
  end

  test "another subject's scoped grant does not open this subject's gate" do
    scope_grant(@bob, role("Editor", "reports#index"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
  end

  # --- R5: persisted-record decisions are unchanged (the anti-regression set) ---

  test "R5: a scoped grant on X still grants nothing on sibling Y" do
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#show", record: @report),
      "the grant on X still works via the untouched scoped_grant? path"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: @other),
      "the record-less branch must NEVER fire for a persisted instance"
  end

  test "R5: a scoped grant on X does not open an unticked key on X" do
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
  end

  test "R5: an unpersisted instance is not a record-less target" do
    scope_grant(@alice, role("Editor", "reports#create"), @report)

    # A new_record? instance answers new_record? — it is an instance, so the
    # record-less branch skips it and scoped_grant? (which needs persisted?)
    # denies. Unchanged behavior; pinned so the branch can't widen to instances.
    assert_not @resolver.allow?(subject: @alice, permission: "reports#create", record: Report.new)
  end

  test "R5: the SoD veto still runs upstream of the record-less branch" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
    # Bob initiated @report AND holds a scoped grant on it that ticks approve.
    scope_grant(@bob, role("Reviewer", "reports#approve"), @report)

    allowed, reason = @resolver.decide(subject: @bob, permission: "reports#approve", record: @report)
    assert_not allowed, "the veto must still beat a scoped grant on a persisted record"
    assert_equal :sod_veto, reason
  ensure
    CurrentScope.config.sod_actions = original
  end

  # --- Ordering: the pre-existing allow paths win before the new branch ---

  test "an org-wide grant is unchanged and resolves before the new branch" do
    assign(@alice, role("Member", "reports#index"))

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
  end

  test "full_access is unchanged" do
    assign(@alice, role("Owner", full_access: true))

    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
  end

  # --- KTD-3 / OQ-2: the branch is uniform across record-less targets ---

  test "OQ-2: a scoped role that ticks a collection key opens that gate too" do
    # Accepted consequence of the uniform record-less rule (KTD-3): identical to
    # how an org grant of `create` already behaves, and there is no record filter
    # on create regardless. Pinned so a change here is a deliberate decision.
    scope_grant(@alice, role("Editor", "reports#create"), @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#create", record: nil)
  end

  test "OQ-2: a nil-record SoD action ticked by a scoped role now resolves allow" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
    # Reachable ONLY when a host mis-gates a member SoD action with a nil record
    # (what warn_on_nil_sod_record exists to catch). No veto is skipped that an
    # org grant of the same key wouldn't also skip: sod_decision already returns
    # :none for any record-less target, so there was never a veto here to sit
    # downstream of. The Guard's nudge still fires — see SodNilRecordNudgeTest.
    scope_grant(@bob, role("Reviewer", "reports#approve"), @report)

    allowed, reason = @resolver.decide(subject: @bob, permission: "reports#approve", record: nil)
    assert allowed
    assert_nil reason
  ensure
    CurrentScope.config.sod_actions = original
  end

  # --- R6: the resolver stays a pure decision function ---

  test "R6: the new branch only reads — no rows are written" do
    scope_grant(@alice, role("Editor", "reports#index"), @report)

    assert_no_difference [ "CurrentScope::Event.count", "CurrentScope::ScopedRoleAssignment.count" ] do
      @resolver.allow?(subject: @alice, permission: "reports#index", record: nil)
      @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)
      @resolver.allow?(subject: @alice, permission: "reports#destroy", record: nil)
    end
  end
end
