require "test_helper"

class ResolverTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @alice = User.create!(name: "Alice")
    @bob = User.create!(name: "Bob")
    @report = Report.create!(title: "Q3", requested_by: @bob)
    @original_sod_identity = CurrentScope.config.sod_identity
    # SoD is opt-in (empty by default); this suite exercises the veto, so enable it.
    @original_sod_actions = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
  end

  teardown do
    CurrentScope.config.sod_identity = @original_sod_identity
    CurrentScope.config.sod_actions = @original_sod_actions
  end

  def assign(user, role)
    CurrentScope::RoleAssignment.create!(subject: user, role: role)
  end

  def role(name, *keys, full_access: false)
    r = CurrentScope::Role.create!(name: name, full_access: full_access)
    keys.each { |k| r.role_permissions.create!(permission_key: k) }
    r
  end

  test "denies a nil subject (fail closed)" do
    assert_not @resolver.allow?(subject: nil, permission: "reports#index")
  end

  test "denies a subject with no role and no scoped grants (default deny)" do
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "denies when the org-wide role lacks the permission" do
    assign(@alice, role("Member", "reports#index"))
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy")
  end

  test "allows when the org-wide role grants the permission" do
    assign(@alice, role("Member", "reports#index"))
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
  end

  test "full_access grants everything, including future permissions" do
    assign(@alice, role("Owner", full_access: true))
    assert @resolver.allow?(subject: @alice, permission: "reports#index")
    assert @resolver.allow?(subject: @alice, permission: "things#added_next_sprint")
  end

  test "SoD veto: the initiator cannot approve their own record" do
    assign(@bob, role("Reviewer", "reports#approve"))
    assert_not @resolver.allow?(subject: @bob, permission: "reports#approve", record: @report)
  end

  test "SoD veto overrides full_access" do
    assign(@bob, role("Owner", full_access: true))
    assert_not @resolver.allow?(subject: @bob, permission: "reports#approve", record: @report)
    assert @resolver.allow?(subject: @bob, permission: "reports#destroy", record: @report)
  end

  test "SoD does not block a different subject" do
    assign(@alice, role("Reviewer", "reports#approve"))
    assert @resolver.allow?(subject: @alice, permission: "reports#approve", record: @report)
  end

  test "SoD only applies to configured actions" do
    assign(@bob, role("Editor", "reports#update"))
    assert @resolver.allow?(subject: @bob, permission: "reports#update", record: @report)
  end

  test "SoD fails loud, not open, when the initiator hook is missing" do
    assign(@alice, role("Owner", full_access: true))
    project = Project.create!(name: "Apollo")   # Project defines no initiator hook

    error = assert_raises(CurrentScope::ConfigurationError) do
      @resolver.allow?(subject: @alice, permission: "projects#approve", record: project)
    end
    assert_match "current_scope_initiator", error.message
  end

  test "SoD accepts a private initiator hook" do
    klass = Class.new(Report) do
      def self.name = "Report"
      private def current_scope_initiator = requested_by
    end
    record = klass.find(@report.id)
    assign(@bob, role("Owner", full_access: true))

    assert_not @resolver.allow?(subject: @bob, permission: "reports#approve", record: record)
  end

  test "a nil initiator exempts the record from the veto" do
    klass = Class.new(Report) do
      def self.name = "Report"
      def current_scope_initiator = nil
    end
    record = klass.find(@report.id)
    assign(@bob, role("Reviewer", "reports#approve"))

    assert @resolver.allow?(subject: @bob, permission: "reports#approve", record: record)
  end

  test "SoD never vetoes class-form checks" do
    assign(@bob, role("Reviewer", "reports#approve"))
    assert @resolver.allow?(subject: @bob, permission: "reports#approve", record: Report)
  end

  test "scoped role grants the permission on that record only" do
    editor = role("Editor", "reports#show")
    other = Report.create!(title: "Q4", requested_by: @bob)
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#show", record: @report)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#show", record: other)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
  end

  test "scoped full_access role grants any action on that record" do
    owner = role("RecordOwner", full_access: true)
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: owner, resource: @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#destroy", record: @report)
  end

  test "a class as record works for collection-action checks" do
    assign(@alice, role("Member", "reports#create"))
    assert @resolver.allow?(subject: @alice, permission: "reports#create", record: Report)
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", record: Report)
  end

  # A scoped grant opens the record-less gate for the keys its role ticks (so the
  # subject can reach the list scope_for narrows — see CollectionScopeGateTest),
  # but it is still not an org-wide grant: it confers nothing on any OTHER
  # record, and nothing on a key the role does not tick.
  test "scoped role never leaks into org-wide reach over other records" do
    editor = role("Editor", "reports#index")
    other = Report.create!(title: "Q4", requested_by: @bob)
    CurrentScope::ScopedRoleAssignment.create!(subject: @alice, role: editor, resource: @report)

    assert @resolver.allow?(subject: @alice, permission: "reports#index", model: Report),
      "the record-less gate opens for the declared type — scope_for narrows the list"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#index", record: other),
      "but the grant on @report must confer nothing on a sibling record"
    assert_not @resolver.allow?(subject: @alice, permission: "reports#destroy", model: Report),
      "and nothing on a key the role does not tick"
  end

  # --- SoD with two identities (:either default) ---

  test "SoD :either vetoes a record the real actor initiated while impersonating" do
    CurrentScope.config.sod_identity = :either
    assign(@alice, role("Reviewer", "reports#approve"))   # the effective subject may approve

    # @report was initiated by @bob, the REAL actor standing behind @alice.
    assert_not @resolver.allow?(
      subject: @alice, permission: "reports#approve", record: @report, actor: @bob
    )
  end

  test "SoD :subject ignores the real actor's initiation" do
    CurrentScope.config.sod_identity = :subject
    assign(@alice, role("Reviewer", "reports#approve"))

    assert @resolver.allow?(
      subject: @alice, permission: "reports#approve", record: @report, actor: @bob
    )
  end

  test "SoD does not veto when neither subject nor actor initiated the record" do
    CurrentScope.config.sod_identity = :either
    carol = User.create!(name: "Carol")
    assign(@alice, role("Reviewer", "reports#approve"))

    assert @resolver.allow?(
      subject: @alice, permission: "reports#approve", record: @report, actor: carol
    )
  end

  test "SoD :either still vetoes the subject's own record when not impersonating" do
    CurrentScope.config.sod_identity = :either
    assign(@bob, role("Reviewer", "reports#approve"))

    # actor omitted -> defaults to the subject -> not impersonating -> :either == :subject.
    assert_not @resolver.allow?(subject: @bob, permission: "reports#approve", record: @report)
  end

  # --- Internal decision method reports a machine-readable reason ---

  test "decide reports :sod_veto, :no_grant, and grants with no reason" do
    assign(@bob, role("Reviewer", "reports#approve"))
    allowed, reason = @resolver.decide(subject: @bob, permission: "reports#approve", record: @report)
    assert_not allowed
    assert_equal :sod_veto, reason

    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index")
    assert_not allowed
    assert_equal :no_grant, reason

    assign(@alice, role("Member", "reports#index"))
    allowed, reason = @resolver.decide(subject: @alice, permission: "reports#index")
    assert allowed
    assert_nil reason
  end
end
