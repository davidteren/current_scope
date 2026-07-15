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

  # The record-less branch requires an EXPLICIT tick, so a scoped full_access
  # role does NOT open it. A full_access role satisfies every key, and this is
  # the one grant check bound to no record — wildcarding it would turn a single
  # scoped grant on a single record into a pass on every #index and #create in
  # the host app. That is reachable with stock data: seed_defaults! ships a
  # full_access "Owner" role and the scoped picker offers every role.
  test "a scoped full_access role does NOT open record-less gates app-wide" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    %w[reports#index reports#create projects#index documents#create widgets#anything].each do |key|
      assert_not @resolver.allow?(subject: @alice, permission: key, record: nil),
        "one scoped full_access grant on one Report must not open #{key}"
      assert_not @resolver.allow?(subject: @alice, permission: key, record: Report),
        "nor the class form of #{key}"
    end
  end

  # A role can be full_access AND carry explicit rows — tick grid cells, then
  # flip the full-access toggle. Matching on the leftover row would walk it right
  # back through the branch full_access is barred from.
  test "a scoped full_access role with explicit permission rows is still barred" do
    owner = role("Owner", "reports#index", full_access: true)
    scope_grant(@alice, owner, @report)

    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: nil),
      "the explicit row must not smuggle a full_access role past the exclusion"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: Report)

    # Unchanged where it is bound to a record: full_access still means full
    # access to the record it was granted on.
    assert @resolver.allow?(subject: @alice, permission: "reports#index", record: @report)
  end

  test "a scoped full_access role still grants everything on its OWN record" do
    scope_grant(@alice, role("Owner", full_access: true), @report)

    # The per-record half is untouched — scoped_grant? binds by `resource:`, so
    # full_access is safe to wildcard there. This is what the grant means.
    assert @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @other)
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

    # Report.new is neither nil nor a Class, so the record-less branch skips it,
    # and scoped_grant? needs persisted? — denied. Only reachable by gating a
    # collection action with Model.new instead of the documented nil, and it
    # fails closed. Pinned so the branch can't widen to instances.
    assert_not @resolver.allow?(subject: @alice, permission: "reports#create", record: Report.new)
  end

  # The record-less test is POSITIVE (nil or a Class) precisely so these fail
  # closed. A negative `unless record.respond_to?(:new_record?)` admits an open
  # set: a host whose current_scope_record wrongly returns params[:id] would
  # hand a String to the gate and be ALLOWED here on the strength of a grant
  # held over some OTHER record — privilege escalation, and the exact inversion
  # of "a grant on X must not act on Y".
  test "R5: a non-record target fails CLOSED, never open" do
    # Alice is scoped on @report ONLY, and holds no org grant.
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    [ @other.id.to_s, @other.id, :garbage, "anything", 42, {}, [], Object.new ].each do |target|
      assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: target),
        "a #{target.class} target must never be treated as record-less — it would grant " \
        "access off a scoped grant held over a different record"
    end
  end

  test "R5: a non-record target is denied even when it names a granted record" do
    scope_grant(@alice, role("Editor", "reports#show"), @report)

    # Naming the very record she IS scoped on must not help either — the gate
    # decides on records, not on strings that look like ids.
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: @report.id.to_s)
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

  # An SoD action is record-targeted by definition, so a record-less SoD check is
  # a contradiction — there is no record for the veto to measure. The branch
  # refuses rather than handing out a four-eyes action with the veto skipped,
  # which is what a host mis-gating `reports#approve` with a nil record would
  # otherwise get. The veto is a structural guarantee; it must not depend on an
  # opt-in dev warning.
  test "a record-less SoD action is never opened by a scoped grant" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
    scope_grant(@alice, role("Reviewer", "reports#approve"), @report) # alice did NOT initiate it

    [ nil, Report ].each do |target|
      allowed, reason = @resolver.decide(subject: @alice, permission: "reports#approve", record: target)
      assert_not allowed, "a record-less SoD target (#{target.inspect}) must not be opened by a scoped grant"
      assert_equal :no_grant, reason
    end

    # The same grant still works where SoD can actually be evaluated.
    assert @resolver.allow?(subject: @alice, permission: "reports#approve", record: @report)
  ensure
    CurrentScope.config.sod_actions = original
  end

  test "the SoD exclusion tracks config, not a hardcoded action list" do
    original = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = []
    scope_grant(@alice, role("Reviewer", "reports#approve"), @report)

    # approve is not an SoD action here, so it is an ordinary collection key.
    assert @resolver.allow?(subject: @alice, permission: "reports#approve", record: nil)
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
