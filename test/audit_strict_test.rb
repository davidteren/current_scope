require "test_helper"
require "current_scope/test_helpers"

# A6: config.audit is tri-state — false | true | :strict.
#   false  → off (no-op)
#   true   → default graceful-degrade (missing table warns once, returns nil)
#   :strict→ missing table RE-RAISES, so a mutation-wrapping transaction rolls
#            back rather than committing an unaudited grant.
class AuditStrictModeTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  setup do
    @actor = User.create!(name: "Admin")
    @role = CurrentScope::Role.create!(name: "Owner")
    @original_audit = CurrentScope.config.audit
  end

  teardown do
    CurrentScope.config.audit = @original_audit
  end

  # Force the real "missing table" path: a StatementInvalid whose message
  # matches missing_events_table? (the existing with_failing_event_record helper
  # raises a bare RuntimeError, which never exercises this rescue).
  def with_missing_events_table(message: "SQLite3::SQLException: no such table: current_scope_events")
    original = CurrentScope::Event.method(:create!)
    CurrentScope::Event.define_singleton_method(:create!) { |*, **| raise ActiveRecord::StatementInvalid, message }
    yield
  ensure
    CurrentScope::Event.define_singleton_method(:create!, original)
  end

  test "default (true): missing table degrades gracefully, returns nil" do
    CurrentScope.config.audit = true
    with_current_user(@actor) do
      result = with_missing_events_table do
        CurrentScope::Event.record!(event: "role.created", target: @role)
      end
      assert_nil result
    end
  end

  test "strict: missing table re-raises" do
    CurrentScope.config.audit = :strict
    with_current_user(@actor) do
      with_missing_events_table do
        assert_raises(ActiveRecord::StatementInvalid) do
          CurrentScope::Event.record!(event: "role.created", target: @role)
        end
      end
    end
  end

  test "off (false): no-op before touching the table" do
    CurrentScope.config.audit = false
    with_missing_events_table do
      assert_nil CurrentScope::Event.record!(event: "role.created", target: @role)
    end
  end

  test "strict is truthy — the top guard still attempts the record when the table exists" do
    CurrentScope.config.audit = :strict
    with_current_user(@actor) do
      assert_difference -> { CurrentScope::Event.count }, 1 do
        CurrentScope::Event.record!(event: "role.created", target: @role)
      end
    end
  end

  test "missing COLUMN (not table) still raises in every mode" do
    CurrentScope.config.audit = true
    with_current_user(@actor) do
      with_missing_events_table(message: "no such column: current_scope_events.nope") do
        assert_raises(ActiveRecord::StatementInvalid) do
          CurrentScope::Event.record!(event: "role.created", target: @role)
        end
      end
    end
  end

  # Rollback on ≥2 distinct mutation-wrapping paths (the guarantee, per review).
  test "strict rolls back path 1 — an org-wide role assignment" do
    CurrentScope.config.audit = :strict
    grantee = User.create!(name: "Grantee1")
    with_current_user(@actor) do
      with_missing_events_table do
        assert_no_difference -> { CurrentScope::RoleAssignment.count } do
          assert_raises(ActiveRecord::StatementInvalid) do
            ActiveRecord::Base.transaction do
              CurrentScope::RoleAssignment.create!(subject: grantee, role: @role)
              CurrentScope::Event.record!(event: "org_role.assigned", target: grantee)
            end
          end
        end
      end
    end
  end

  test "strict rolls back path 2 — a scoped role assignment" do
    CurrentScope.config.audit = :strict
    grantee = User.create!(name: "Grantee2")
    record = Report.create!(title: "R", requested_by: @actor)
    with_current_user(@actor) do
      with_missing_events_table do
        assert_no_difference -> { CurrentScope::ScopedRoleAssignment.count } do
          assert_raises(ActiveRecord::StatementInvalid) do
            ActiveRecord::Base.transaction do
              CurrentScope::ScopedRoleAssignment.create!(subject: grantee, role: @role, resource: record)
              CurrentScope::Event.record!(event: "scoped_role.granted", target: grantee)
            end
          end
        end
      end
    end
  end
end
