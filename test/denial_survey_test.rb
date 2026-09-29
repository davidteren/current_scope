require "test_helper"

# The composite answer over the report classifier. A found problem outranks a
# check that could not run. That outranks "nothing to act on". None of the three
# headlines is permission to set :enforce.
class DenialSurveyTest < ActiveSupport::TestCase
  NOT_READY = "CurrentScope preflight: NOT READY. A check found a problem."
  CANNOT_TELL = "CurrentScope preflight: CANNOT TELL. A required check could not run."
  NOTHING = "CurrentScope preflight: nothing to act on in the checks that ran."
  SKIP_LIMIT = "Limit: this lists only what the callback chain PROVES. A conditional skip " \
               "(skip_before_action only:/except:) does not appear here — set " \
               "config.gating_tripwire = :warn and include CurrentScope::GatingTripwire " \
               "to inventory those at runtime."

  setup { CurrentScope::Event.delete_all }

  test "a still-denied row is NOT READY even when the SoD preflight is degraded" do
    alice = User.create!(name: "Alice")
    would_deny(alice, "reports#index")
    singleton = CurrentScope::SodPreflight.singleton_class
    original = CurrentScope::SodPreflight.method(:declared_model_for)
    singleton.define_method(:declared_model_for) do |path, _reflection, skipped|
      skipped << [ path, RuntimeError.new("the host's hook blew up") ]
      nil
    end

    assembly, = assemble_in(sod_actions: %w[show], grouped: { "reports" => [ "show" ] })

    assert_equal NOT_READY, assembly.headline
    assert assembly.why.any? { |line| line.include?("could not complete") },
           "a cannot-tell fact stays on the Why list when a problem outranks it"
    assert assembly.act_on.values.any?(&:positive?)
    refute_match(/safe to enforce/, spoken(assembly))
  ensure
    singleton.define_method(:declared_model_for, original)
    singleton.send(:private, :declared_model_for)
  end

  test "enforce mode with an empty ledger is CANNOT TELL and names enforcement" do
    assembly, = assemble_in(enforcement: :enforce)

    assert_equal CANNOT_TELL, assembly.headline
    assert assembly.why.any? { |line| line.include?(":enforce") }, assembly.why.inspect
    refute_equal NOTHING, assembly.headline
  end

  test "audit off is CANNOT TELL" do
    assembly, = assemble_in(audit: false)

    assert_equal CANNOT_TELL, assembly.headline
    assert assembly.why.any? { |line| line.match?(/audit/i) }, assembly.why.inspect
  end

  test "audit :strict with an otherwise clean survey is nothing to act on" do
    assembly, = assemble_in(audit: :strict)

    assert_equal NOTHING, assembly.headline
  end

  test "a blind SoD preflight is CANNOT TELL" do
    ReportsController.send(:remove_method, :current_scope_model)

    assembly, = assemble_in(sod_actions: %w[approve], grouped: { "reports" => [ "approve" ] })

    assert_equal CANNOT_TELL, assembly.headline
    assert assembly.why.any? { |line| line.match?(/blind/i) }, assembly.why.inspect
    refute assembly.why.any? { |line| line.include?("could not complete") },
           "nothing failed; the run read nothing"
  ensure
    unless ReportsController.private_method_defined?(:current_scope_model)
      ReportsController.send(:define_method, :current_scope_model) { Report }
      ReportsController.send(:private, :current_scope_model)
    end
  end

  test "a missing controller is CANNOT TELL and names the path" do
    assembly, = assemble_in(grouped: { "orphaned" => [ "index" ] })

    assert_equal CANNOT_TELL, assembly.headline
    assert assembly.why.any? { |line| line.include?("orphaned") }, assembly.why.inspect
  end

  test "an ungated controller is NOT READY and names that controller" do
    assembly, = assemble_in(grouped: { "bare" => [ "show" ] })

    assert_equal NOT_READY, assembly.headline
    assert assembly.why.any? { |line| line.include?("bare") }, assembly.why.inspect
    assert_includes assembly.not_checked, SKIP_LIMIT
  end

  test "a clean gated survey is nothing to act on and still lists what it did not check" do
    assembly, = assemble_in

    assert_equal NOTHING, assembly.headline
    assert assembly.not_checked.any? { |line| line.match?(/authentication/i) }
    assert_includes assembly.not_checked, SKIP_LIMIT
    assert assembly.not_checked.any? { |line| line.match?(/no recorded traffic/i) }
    assert assembly.not_checked.any? { |line| line.match?(/log lines/i) }
    refute_match(/safe to enforce/, spoken(assembly))
    refute_match(/ready to flip/, spoken(assembly))
    assert_nil assembly.moot_line
  end

  test "a moot-only ledger is not NOT READY and the moot count is not an act-on line" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Gone", requested_by: alice)
    would_deny_on(alice, "reports#show", report.to_gid.to_s)
    report.delete

    assembly, = assemble_in

    assert_equal NOTHING, assembly.headline
    assert_equal 1, assembly.moot_count
    assert_match(/not work to grant/, assembly.moot_line)
    assert_match(/\b1\b/, assembly.moot_line)
    refute_match(/not work to grant/, assembly.act_on.keys.join("\n"))
    assert_empty assembly.act_on
  end

  test "a batch grant-scan rescue is CANNOT TELL when the printed counts are zero" do
    singleton = CurrentScope::ScopedRoleAssignment.singleton_class
    original = CurrentScope::ScopedRoleAssignment.method(:includes)
    singleton.define_method(:includes) { |*| raise ActiveRecord::ActiveRecordError, "boom" }

    survey = nil
    _out, err = capture_io { survey = CurrentScope::DenialSurvey.denials }
    assembly, = assemble_in

    assert survey.grant_scan_rescued
    assert_empty survey.dead_grants
    assert_empty survey.nonconforming_grants
    assert_equal 0, survey.unjudgeable_grants
    assert_match(/could not scan scoped grants/, err)
    assert_equal CANNOT_TELL, assembly.headline
    assert_rescue_why(assembly)
  ensure
    singleton.define_method(:includes, original)
  end

  test "a per-grant rescue with a nonconforming grant stays NOT READY and names the rescue" do
    alice = User.create!(name: "Alice")
    project = Project.create!(name: "Q3")
    scope_grant(alice, role_with("projects#show"), project)
    declare_grantable_roles(Project, [ "Someone Else" ])
    raising_report_grant(alice)

    survey = nil
    _out, err = capture_io { survey = CurrentScope::DenialSurvey.denials }
    assembly, = assemble_in

    assert survey.grant_scan_rescued
    assert_operator survey.nonconforming_grants.size, :>, 0
    assert_match(/reported as conforming/, err)
    assert_equal NOT_READY, assembly.headline
    assert_rescue_why(assembly)
  ensure
    drop_raising_report_grant
  end

  test "a per-grant rescue with a zero nonconforming count is CANNOT TELL and does not call the grant conforming" do
    alice = User.create!(name: "Alice")
    raising_report_grant(alice)

    survey = nil
    _out, err = capture_io { survey = CurrentScope::DenialSurvey.denials }
    assembly, = assemble_in

    assert survey.grant_scan_rescued
    assert_empty survey.nonconforming_grants
    assert_empty survey.signals
    assert_match(/reported as conforming/, err)
    assert_equal CANNOT_TELL, assembly.headline
    assert_rescue_why(assembly)
  ensure
    drop_raising_report_grant
  end

  test "a missing events table is CANNOT TELL and is not the third headline" do
    stub_events_error("no such table: current_scope_events")

    assembly, = assemble_in

    assert_equal CANNOT_TELL, assembly.headline
    refute_equal NOTHING, assembly.headline
    assert assembly.why.any? { |line| line.include?("current_scope:install:migrations") },
           assembly.why.inspect
  ensure
    restore_events_where
  end

  test "a missing events table does not hide a non-zero act-on count" do
    alice = User.create!(name: "Alice")
    report = Report.create!(title: "Q3", requested_by: alice)
    scope_grant(alice, role_with, report)
    stub_events_error("no such table: current_scope_events")

    assembly, = assemble_in

    assert_equal NOT_READY, assembly.headline
    assert assembly.act_on.keys.any? { |label| label.include?("can never match") }, assembly.act_on.inspect
    assert assembly.why.any? { |line| line.include?("current_scope:install:migrations") },
           assembly.why.inspect
  ensure
    restore_events_where
  end

  test "an unrelated database error still raises" do
    stub_events_error("connection refused")

    error = assert_raises(ActiveRecord::StatementInvalid, SystemExit) do
      capture_io { CurrentScope::DenialSurvey.assemble }
    end

    assert_kind_of ActiveRecord::StatementInvalid, error
  ensure
    restore_events_where
  end

  test "a missing column on the events table still raises" do
    stub_events_error("column current_scope_events.details does not exist")

    error = assert_raises(ActiveRecord::StatementInvalid, SystemExit) do
      capture_io { CurrentScope::DenialSurvey.assemble }
    end

    assert_kind_of ActiveRecord::StatementInvalid, error
  ensure
    restore_events_where
  end

  test "an empty permission catalog is CANNOT TELL" do
    assembly, = assemble_in(grouped: {})

    assert_equal CANNOT_TELL, assembly.headline
    assert assembly.why.any? { |line| line.include?("nothing was inspected") }, assembly.why.inspect
    refute_equal NOTHING, assembly.headline
  end

  test "an injected break-glass row is not a missing controller" do
    config = CurrentScope.config
    original_bypass = config.allow_sod_bypass
    config.allow_sod_bypass = true
    CurrentScope.catalog.define_singleton_method(:routed?) { |key| key != "ghost#bypass_sod" }

    assembly, = assemble_in(grouped: { "reports" => [ "index" ], "ghost" => [ "bypass_sod" ] })

    assert_equal NOTHING, assembly.headline
    refute assembly.why.any? { |line| line.include?("ghost") }, assembly.why.inspect
  ensure
    config.allow_sod_bypass = original_bypass
  end

  test "a NoMethodError during the ungated walk keeps its class name" do
    reflection = CurrentScope::GatingReflection
    original = reflection.instance_method(:ungated?)
    reflection.define_method(:ungated?) { |_controller| raise NoMethodError, "boom" }

    assembly, = assemble_in(grouped: { "reports" => [ "index" ] })

    assert_equal CANNOT_TELL, assembly.headline
    assert assembly.why.any? { |line| line.include?("NoMethodError") }, assembly.why.inspect
    refute assembly.why.any? { |line| line.include?("raised NameError") }, assembly.why.inspect
  ensure
    reflection.define_method(:ungated?, original) if original
  end

  test "a degraded SoD preflight with findings does not call the list empty" do
    result = CurrentScope::SodPreflight::Result.new(
      rows: [ [ "reports#approve", Report ] ],
      inspected: 1,
      in_scope: 2,
      skipped: [ [ "invoices", RuntimeError.new("hook blew up") ] ]
    )
    original = CurrentScope::SodPreflight.method(:scan)
    CurrentScope::SodPreflight.define_singleton_method(:scan) { result }

    assembly, = assemble_in

    assert result.degraded?
    assert result.blind?
    assert result.any?
    assert_equal NOT_READY, assembly.headline
    assert assembly.why.any? { |line| line.include?("could not complete") }, assembly.why.inspect
    assert assembly.why.any? { |line| line.match?(/blind/i) }, assembly.why.inspect
    refute assembly.why.any? { |line| line.match?(/empty finding list/i) }, assembly.why.inspect
  ensure
    CurrentScope::SodPreflight.define_singleton_method(:scan, original) if original
  end

  test "a NameError during the ungated walk is CANNOT TELL and names the controller" do
    assert_raises(NameError) { CurrentScope::GatingReflection.new.ungated?("broken_constant") }

    assembly, = assemble_in(grouped: { "broken_constant" => [ "index" ] })

    assert_equal CANNOT_TELL, assembly.headline
    assert assembly.why.any? { |line| line.include?("broken_constant") }, assembly.why.inspect
  end

  test "a later ungated controller stays NOT READY when an earlier controller raises NameError" do
    assembly, = assemble_in(grouped: { "broken_constant" => [ "index" ], "bare" => [ "show" ] })

    assert_equal NOT_READY, assembly.headline
    assert assembly.why.any? { |line| line.include?("broken_constant") }, assembly.why.inspect
    assert assembly.why.any? { |line| line.include?("bare") }, assembly.why.inspect
  end

  test "assemble reads the SoD result denials already returned and does not scan again" do
    calls = 0
    original = CurrentScope::SodPreflight.method(:scan)
    CurrentScope::SodPreflight.define_singleton_method(:scan) do
      calls += 1
      original.call
    end

    assemble_in
    assert_equal 1, calls
  ensure
    CurrentScope::SodPreflight.define_singleton_method(:scan, original) if original
  end

  test "assemble does not write a ledger row" do
    before = CurrentScope::Event.count
    assemble_in
    assert_equal before, CurrentScope::Event.count
  end

  private

  def spoken(assembly)
    [ assembly.headline, *assembly.why, *assembly.act_on.flatten, assembly.moot_line, *assembly.not_checked ].join("\n")
  end

  def assert_rescue_why(assembly)
    assert assembly.why.any? { |line| line.match?(/grant scan rescued/i) }, assembly.why.inspect
    refute assembly.why.any? { |line| line.match?(/conforming/i) },
           "the Why line must not say the grant is conforming"
  end

  def assemble_in(enforcement: :report, audit: true, sod_actions: [], grouped: { "reports" => [ "index" ] })
    config = CurrentScope.config
    @survey_originals = {
      enforcement: config.enforcement,
      audit: config.audit,
      sod: config.sod_actions
    }
    config.enforcement = enforcement
    config.audit = audit
    config.sod_actions = sod_actions
    CurrentScope.catalog.define_singleton_method(:grouped) { grouped }
    assembly = nil
    _out, err = capture_io { assembly = CurrentScope::DenialSurvey.assemble }
    [ assembly, err ]
  ensure
    restore_survey_scope
  end

  def restore_survey_scope
    return unless @survey_originals

    CurrentScope.config.enforcement = @survey_originals[:enforcement]
    CurrentScope.config.audit = @survey_originals[:audit]
    CurrentScope.config.sod_actions = @survey_originals[:sod]
    @survey_originals = nil
    CurrentScope.reset_catalog!
  end

  def would_deny(subject, permission, count: 1)
    count.times do
      CurrentScope::Event.create!(
        event: "access.would_deny", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
        target: subject.to_gid.to_s, target_label: subject.name,
        details: { "permission" => permission, "reason" => "no_grant" }
      )
    end
  end

  def would_deny_on(subject, permission, target_gid)
    CurrentScope::Event.create!(
      event: "access.would_deny", subject: subject.to_gid.to_s, actor: subject.to_gid.to_s,
      target: target_gid, target_label: "a target",
      details: { "permission" => permission, "reason" => "no_grant", "record_less" => false }
    )
  end

  def role_with(*keys)
    role = CurrentScope::Role.create!(name: "R-#{rand(10**9)}")
    keys.each { |key| role.role_permissions.create!(permission_key: key) }
    role
  end

  def scope_grant(subject, role, resource)
    CurrentScope::ScopedRoleAssignment.create!(subject: subject, role: role, resource: resource)
  end

  def raising_report_grant(subject)
    report = Report.create!(title: "Healthy", requested_by: subject)
    scope_grant(subject, role_with("reports#approve"), report)
    @raising_report = Report.singleton_class
    return if @raising_report.instance_methods(false).include?(:current_scope_grants_role?)

    Report.define_singleton_method(:current_scope_grants_role?) { |*| raise "nope" }
    @drop_raising_report = true
  end

  def drop_raising_report_grant
    return unless @drop_raising_report

    Report.singleton_class.send(:remove_method, :current_scope_grants_role?)
    @drop_raising_report = false
  end

  def stub_events_error(message)
    @events_where = CurrentScope::Event.method(:where)
    CurrentScope::Event.define_singleton_method(:where) do |*|
      raise ActiveRecord::StatementInvalid, message
    end
  end

  def restore_events_where
    return unless @events_where

    CurrentScope::Event.define_singleton_method(:where, @events_where)
    @events_where = nil
  end
end
