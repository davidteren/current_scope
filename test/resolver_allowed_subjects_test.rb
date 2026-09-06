require "test_helper"

class ResolverAllowedSubjectsTest < ActiveSupport::TestCase
  setup do
    @resolver = CurrentScope::Resolver.new
    @requester = User.create!(name: "Requester")
    @reviewer = User.create!(name: "Reviewer")
    @other = User.create!(name: "Other")
    @project = Project.create!(name: "Project")
    @report = Report.create!(title: "Report", requested_by: @requester, project: @project)
    @original_sod = CurrentScope.config.sod_actions
    @original_identity = CurrentScope.config.sod_identity
    CurrentScope.config.sod_actions = %w[approve]
    CurrentScope.config.sod_identity = :either
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod
    CurrentScope.config.sod_identity = @original_identity
  end

  test "batch decisions match scalar global scoped parent and initiator checks" do
    role = CurrentScope::Role.create!(name: "Reviewer", permission_keys: %w[reports#approve])
    CurrentScope::RoleAssignment.create!(subject: @requester, role: role)
    CurrentScope::ScopedRoleAssignment.create!(subject: @reviewer, role: role, resource: @project)
    candidates = [ @requester, @reviewer, @other, nil ]

    [ @report, Report.new(requested_by: @requester, project: @project) ].each do |record|
      expected = candidates.select { |subject| @resolver.allow?(subject: subject, permission: "reports#approve", record: record) }
      assert_equal [ @reviewer ], expected
      assert_equal expected, @resolver.allowed_subjects(subjects: candidates, permission: "reports#approve", record: record)
    end
    assert_empty @resolver.allowed_subjects(subjects: candidates, permission: "reports#approve", record: @report, actor: @requester)
    assert_empty @resolver.allowed_subjects(subjects: [ @reviewer ], permission: "reports#approve", record: @report, cascade: false)
  end

  test "full access remains direct only and does not cascade from a parent" do
    full = CurrentScope::Role.create!(name: "Full", full_access: true, permission_keys: %w[reports#approve])
    CurrentScope::ScopedRoleAssignment.create!(subject: @reviewer, role: full, resource: @project)
    CurrentScope::ScopedRoleAssignment.create!(subject: @other, role: full, resource: @report)

    assert_equal [ @other ], @resolver.allowed_subjects(subjects: [ @reviewer, @other ], permission: "reports#approve", record: @report)
  end

  test "removing permission is visible to the next batch call" do
    role = CurrentScope::Role.create!(name: "Reviewer", permission_keys: %w[reports#approve])
    CurrentScope::ScopedRoleAssignment.create!(subject: @reviewer, role: role, resource: @project)
    assert_equal [ @reviewer ], @resolver.allowed_subjects(subjects: [ @reviewer ], permission: "reports#approve", record: @report)

    role.update!(permission_keys: [])
    assert_empty @resolver.allowed_subjects(subjects: [ @reviewer ], permission: "reports#approve", record: @report)
  end

  test "batch query count does not grow with candidate count" do
    role = CurrentScope::Role.create!(name: "Reviewer", permission_keys: %w[reports#approve])
    CurrentScope::ScopedRoleAssignment.create!(subject: @reviewer, role: role, resource: @project)
    baseline = query_count { @resolver.allowed_subjects(subjects: [ @reviewer ], permission: "reports#approve", record: @report) }
    candidates = [ @reviewer ] + 5.times.map do |index|
      user = User.create!(name: "Reviewer #{index}")
      CurrentScope::ScopedRoleAssignment.create!(subject: user, role: role, resource: @project)
      user
    end
    result = nil
    scaled = query_count { result = @resolver.allowed_subjects(subjects: candidates, permission: "reports#approve", record: @report) }

    assert_equal candidates, result
    assert_equal baseline, scaled
  end

  test "global full access remains subject to the initiator veto and destroyed record parity" do
    full = CurrentScope::Role.create!(name: "Global full", full_access: true)
    CurrentScope::RoleAssignment.create!(subject: @requester, role: full)
    CurrentScope::RoleAssignment.create!(subject: @reviewer, role: full)
    assert_equal [ @reviewer ], @resolver.allowed_subjects(subjects: [ @requester, nil, @reviewer ], permission: "reports#approve", record: @report)

    CurrentScope::ScopedRoleAssignment.create!(subject: @other, role: full, resource: @report)
    @report.destroy!
    candidates = [ @requester, @reviewer, @other ]
    expected = candidates.select { |subject| @resolver.allow?(subject: subject, permission: "reports#show", record: @report) }
    assert_equal expected, @resolver.allowed_subjects(subjects: candidates, permission: "reports#show", record: @report)
  end

  test "subject-only duties use each candidate rather than the supplied actor" do
    role = CurrentScope::Role.create!(name: "Reviewer", permission_keys: %w[reports#approve])
    CurrentScope::RoleAssignment.create!(subject: @reviewer, role: role)
    CurrentScope.config.sod_identity = :subject

    assert_equal [ @reviewer ], @resolver.allowed_subjects(subjects: [ @reviewer ], permission: "reports#approve", record: @report, actor: @requester)
  end

  test "subject types remain distinct when their ids have the same text" do
    other_type = UuidUser.create!(id: @reviewer.id.to_s, name: "Same id different type")
    role = CurrentScope::Role.create!(name: "Reviewer", permission_keys: %w[reports#approve])
    CurrentScope::ScopedRoleAssignment.create!(subject: other_type, role: role, resource: @project)

    assert_equal [ other_type ], @resolver.allowed_subjects(subjects: [ @reviewer, other_type ], permission: "reports#approve", record: @report)
  end

  test "the existing break-glass decision is preserved in a batch" do
    original = CurrentScope.config.allow_sod_bypass
    CurrentScope.config.allow_sod_bypass = true
    role = CurrentScope::Role.create!(name: "Breaker")
    role.role_permissions.create!(permission_key: "reports#bypass_sod")
    CurrentScope::RoleAssignment.create!(subject: @requester, role: role)
    @report.define_singleton_method(:current_scope_sod_bypassed?) { true }

    assert @resolver.allow?(subject: @requester, permission: "reports#approve", record: @report)
    assert_equal [ @requester ], @resolver.allowed_subjects(subjects: [ @requester, @reviewer ], permission: "reports#approve", record: @report)
  ensure
    CurrentScope.config.allow_sod_bypass = original
  end

  test "batch API rejects recordless requests explicitly" do
    [ nil, Report ].each do |record|
      assert_raises(ArgumentError) { @resolver.allowed_subjects(subjects: [ @reviewer ], permission: "reports#index", record: record) }
    end
  end

  private

  def query_count
    count = 0
    listener = lambda do |*, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/) || payload[:cached]
    end
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") { yield }
    count
  end
end
