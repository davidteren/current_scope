require "test_helper"
require "current_scope/test_helpers"

class EventTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  setup do
    @alice = User.create!(name: "Alice")
    @admin = User.create!(name: "Admin")
  end

  teardown { CurrentScope.config.audit = true }

  # --- readonly? (append-only ceiling) -------------------------------------

  test "a persisted event is readonly — refuses update and destroy" do
    event = with_current_user(@alice) { record_role_event }

    assert event.readonly?
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(request_id: "x") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
  end

  test "a new (unpersisted) event is not readonly" do
    assert_not CurrentScope::Event.new.readonly?
  end

  # --- missing actor fails loud --------------------------------------------

  test "record! raises ConfigurationError when there is no ambient actor" do
    role = CurrentScope::Role.create!(name: "Owner")

    assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope::Event.record!(event: "role.created", target: role)
    end
  end

  test "record! accepts explicit actor without ambient context (#30)" do
    role = CurrentScope::Role.create!(name: "Owner")
    CurrentScope::Current.reset

    event = CurrentScope::Event.record!(
      event: "role.created", target: role, actor: @alice, subject: @alice
    )
    assert_equal @alice.to_gid.to_s, event.actor
    assert_equal @alice.to_gid.to_s, event.subject
  end

  test "explicit actor and subject beat ambient user (self-attribution guard)" do
    role = CurrentScope::Role.create!(name: "Owner")
    CurrentScope::Current.user = @admin
    CurrentScope::Current.actor = @admin

    event = CurrentScope::Event.record!(
      event: "role.created", target: role, actor: @alice, subject: @alice
    )
    assert_equal @alice.to_gid.to_s, event.actor
    assert_equal @alice.to_gid.to_s, event.subject
  ensure
    CurrentScope::Current.reset
  end

  # --- actor / subject capture ---------------------------------------------

  test "record! captures actor and subject; subject == actor when not impersonating" do
    event = with_current_user(@alice) { record_role_event }

    assert_equal @alice.to_gid.to_s, event.actor
    assert_equal @alice.to_gid.to_s, event.subject
    assert_equal event.actor, event.subject
  end

  test "record! records subject <> actor while impersonating" do
    event = with_current_user(@alice, actor: @admin) { record_role_event(event: "role.renamed") }

    assert_equal @admin.to_gid.to_s, event.actor  # the real actor
    assert_equal @alice.to_gid.to_s, event.subject # the effective subject
    assert_not_equal event.actor, event.subject
  end

  # --- denormalized label survives target deletion -------------------------

  test "target_label survives target deletion" do
    role = CurrentScope::Role.create!(name: "Owner")
    event = with_current_user(@alice) { CurrentScope::Event.record!(event: "role.created", target: role) }
    label = event.target_label

    assert label.present?
    role.destroy
    assert_equal label, event.reload.target_label
  end

  test "label_for prefers a record's own current_scope_label" do
    labeled = Class.new { def current_scope_label = "Custom Label" }.new
    assert_equal "Custom Label", CurrentScope::Event.send(:label_for, labeled)
  end

  # --- audit toggle --------------------------------------------------------

  test "record! is a silent no-op when audit is off" do
    CurrentScope.config.audit = false

    result = with_current_user(@alice) { record_role_event }

    assert_nil result
    assert_equal 0, CurrentScope::Event.count
  end

  # --- friendly error when the host hasn't migrated ------------------------

  test "record! degrades gracefully (no raise, warns once) when the events table is missing" do
    role = CurrentScope::Role.create!(name: "Owner")
    # A subclass bound to a table that doesn't exist reproduces the real
    # "no such table" StatementInvalid an unmigrated host hits. Audit is on by
    # default, so this must NOT break the mutation — it skips recording and warns.
    unmigrated = Class.new(CurrentScope::Event) { self.table_name = "current_scope_events_missing" }

    io = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    begin
      with_current_user(@alice) do
        assert_nil unmigrated.record!(event: "role.created", target: role) # no raise, no-op
        unmigrated.record!(event: "role.created", target: role)            # second call: no re-warn
      end
    ensure
      Rails.logger = original_logger
    end

    log = io.string
    assert_match(/current_scope_events table is missing/, log)
    assert_match(/current_scope:install:migrations/, log)
    assert_equal 1, log.scan("audit is on but the current_scope_events table is missing").size,
                 "should warn once, not on every call"
  end

  # --- frozen schema: null constraints -------------------------------------

  test "core columns are NOT NULL and payload columns are nullable (frozen schema)" do
    cols = CurrentScope::Event.columns_hash

    %w[event actor subject target target_label created_at].each do |c|
      assert_not cols[c].null, "#{c} must be NOT NULL"
    end
    %w[details request_id].each do |c|
      assert cols[c].null, "#{c} must be nullable"
    end
    assert_nil cols["updated_at"], "there must be no updated_at (append-only)"
  end

  # --- normative target mapping --------------------------------------------

  test "normative target: a role.* event targets the role" do
    role = CurrentScope::Role.create!(name: "Owner")
    event = with_current_user(@alice) { CurrentScope::Event.record!(event: "role.created", target: role) }

    assert_equal role.to_gid.to_s, event.target
  end

  test "normative target: a scoped_role.* event targets the grantee" do
    event = with_current_user(@admin) do
      CurrentScope::Event.record!(event: "scoped_role.granted", target: @alice) # grantee == subject being granted
    end

    assert_equal @alice.to_gid.to_s, event.target
  end

  private

  def record_role_event(event: "role.created")
    role = CurrentScope::Role.create!(name: "Owner-#{SecureRandom.hex(4)}")
    CurrentScope::Event.record!(event: event, target: role)
  end
end
