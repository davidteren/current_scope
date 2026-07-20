require "test_helper"

# A11: CurrentScope.grant! bootstraps the first admin (backs the
# current_scope:grant rake task), so the initial full_access assignment isn't a
# bare console step.
class GrantTest < ActiveSupport::TestCase
  setup { @user = User.create!(name: "First Admin") }

  test "grants the full-access Owner role as the subject's org-wide role" do
    CurrentScope.grant!(@user)

    role = CurrentScope::RoleAssignment.find_by(subject: @user)&.role
    assert role, "expected an org-wide role assignment"
    assert_equal "Owner", role.name
    assert role.full_access?
    assert CurrentScope.resolver.full_access?(@user)
  end

  test "is idempotent — re-running does not duplicate the assignment" do
    CurrentScope.grant!(@user)
    assert_no_difference -> { CurrentScope::RoleAssignment.where(subject: @user).count } do
      CurrentScope.grant!(@user)
    end
  end

  test "upgrades an existing non-owner subject to Owner" do
    member = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @user, role: member)

    CurrentScope.grant!(@user)

    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: @user).role.name
  end

  # grant! promises "assign a role" — passing an explicit role must not ALSO
  # create a full-access Owner (and a Member) in the roles table as a side
  # effect. Seeding belongs to the default path only.
  test "granting an explicit role seeds no default roles" do
    custom = CurrentScope::Role.create!(name: "Custom")

    assert_no_difference -> { CurrentScope::Role.count } do
      CurrentScope.grant!(@user, role: custom)
    end

    assert_equal custom, CurrentScope::RoleAssignment.find_by(subject: @user).role
    assert_not CurrentScope::Role.exists?(name: "Owner"),
               "no full-access Owner may appear as a side effect of an explicit grant"
  end

  # --- #30 bootstrap audit ---

  test "grant! records org_role.assigned self-attributed with source bootstrap" do
    CurrentScope::Current.reset

    assert_difference -> { CurrentScope::Event.where(event: "org_role.assigned").count }, 1 do
      CurrentScope.grant!(@user)
    end

    event = CurrentScope::Event.where(event: "org_role.assigned").order(:id).last
    assert_equal @user.to_gid.to_s, event.actor
    assert_equal @user.to_gid.to_s, event.subject
    assert_equal "Owner", event.details["role"]
    assert_equal "bootstrap", event.details["source"]
    assert_nil event.request_id, "bootstrap has no request"
  end

  test "grant! records org_role.changed when replacing a different role" do
    member = CurrentScope::Role.create!(name: "Member")
    CurrentScope::RoleAssignment.create!(subject: @user, role: member)

    assert_difference -> { CurrentScope::Event.where(event: "org_role.changed").count }, 1 do
      CurrentScope.grant!(@user)
    end

    event = CurrentScope::Event.where(event: "org_role.changed").order(:id).last
    assert_equal "Member", event.details["from"]
    assert_equal "Owner", event.details["to"]
    assert_equal "bootstrap", event.details["source"]
  end

  test "grant! same-role re-grant records no second event" do
    CurrentScope.grant!(@user)
    assert_no_difference -> { CurrentScope::Event.count } do
      CurrentScope.grant!(@user)
    end
  end

  test "grant! with audit off still assigns and records nothing" do
    original = CurrentScope.config.audit
    CurrentScope.config.audit = false
    assert_no_difference -> { CurrentScope::Event.count } do
      CurrentScope.grant!(@user)
    end
    assert CurrentScope::RoleAssignment.find_by(subject: @user)
  ensure
    CurrentScope.config.audit = original
  end

  test "grant! self-attributes even when ambient user is a different admin" do
    admin = User.create!(name: "Other Admin")
    CurrentScope::Current.user = admin
    CurrentScope::Current.actor = admin

    CurrentScope.grant!(@user)

    event = CurrentScope::Event.where(event: "org_role.assigned").order(:id).last
    assert_equal @user.to_gid.to_s, event.actor
    assert_equal @user.to_gid.to_s, event.subject
  ensure
    CurrentScope::Current.reset
  end

  # PR #102: missing events table must not poison grant!'s outer transaction
  # (PostgreSQL aborts the whole txn on StatementInvalid unless the audit write
  # is isolated in a savepoint — Event.record! uses requires_new).
  test "grant! with audit=true still assigns when events table is missing" do
    original_audit = CurrentScope.config.audit
    CurrentScope.config.audit = true
    original_create = CurrentScope::Event.method(:create!)
    # |*, **| — create! is called with keyword args; a bare |*| raises
    # ArgumentError on Ruby 3.1+ and never exercises the missing-table path
    # (same pattern as audit_strict_test.rb).
    CurrentScope::Event.define_singleton_method(:create!) do |*, **|
      raise ActiveRecord::StatementInvalid, "SQLite3::SQLException: no such table: current_scope_events"
    end

    assert_difference -> { CurrentScope::RoleAssignment.where(subject: @user).count }, 1 do
      assert_nothing_raised { CurrentScope.grant!(@user) }
    end
    assert_equal "Owner", CurrentScope::RoleAssignment.find_by(subject: @user).role.name
  ensure
    CurrentScope::Event.define_singleton_method(:create!, original_create)
    CurrentScope.config.audit = original_audit
  end
end
