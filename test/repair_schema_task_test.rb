require "test_helper"
require "rake"

# #151. The repair task exists because db:migrate CANNOT fix a schema-loaded
# database: loading a schema stamps every migration version as applied, so there
# is nothing pending — while schema.rb cannot carry a MySQL collation, leaving
# the columns case-insensitive and the engine unbootable. That was a dead end
# with no way out, and this task is the way out, so it needs its own coverage
# rather than being exercised only as a side effect of bin/db and CI.
class RepairSchemaTaskTest < ActiveSupport::TestCase
  # The task runs real DDL. MySQL auto-commits it, which would destroy the test's
  # savepoint — the same reason the migration test opts out.
  self.use_transactional_tests = false

  setup do
    Rake::Task.clear
    Rake::TaskManager.record_task_metadata = true
    load Rails.root.join("../../lib/tasks/current_scope_tasks.rake").expand_path
    Rake::Task.define_task(:environment)
  end

  teardown { Rake::Task.clear }

  def run_repair
    Rake::Task["current_scope:repair_schema"].reenable
    capture_io { Rake::Task["current_scope:repair_schema"].invoke }
  end

  def connection = ActiveRecord::Base.connection

  test "it leaves every grant id and type column in the shape #151 requires" do
    run_repair

    mysql = CurrentScope.mysql?(connection)
    {
      "current_scope_role_assignments" => %w[subject_id subject_type],
      "current_scope_scoped_role_assignments" => %w[subject_id resource_id subject_type resource_type]
    }.each do |table, columns|
      columns.each do |name|
        info = connection.columns(table).find { |c| c.name == name }
        assert_equal :string, info.type, "#{table}.#{name} must be a string column"
        assert_equal CurrentScope::KEY_LIMIT, info.limit, "#{table}.#{name} width" if name.end_with?("_id")

        next unless mysql

        assert info.collation.to_s.end_with?("_bin"),
               "#{table}.#{name} is #{info.collation}: a case-insensitive collation means " \
               "\"ABC\" and \"abc\" are the same record, which is #151 by another column"
      end
    end
  end

  test "running it twice is a no-op, so an operator can re-run it safely" do
    run_repair
    assert_nothing_raised { run_repair }
  end

  test "it says what it did, and only claims the collation on the adapter that got one" do
    out, _err = run_repair

    assert_match(/#{CurrentScope::KEY_LIMIT}-character/, out)
    if CurrentScope.mysql?(connection)
      assert_match(/binary-collated/, out)
    else
      assert_no_match(/binary-collated/, out,
                      "PostgreSQL and SQLite already compare byte for byte — this task sets " \
                      "no collation there, so claiming one would be a false report")
    end
  end

  # The boot check refuses to serve on an unrepaired schema, and this task is the
  # repair. If its own name were not exempt, running it would be impossible for
  # exactly the reason it exists — the dead end this fix removed.
  test "the task's own name is exempt from the boot refusal" do
    exempt = CurrentScope::SchemaGuard::BOOT_EXEMPT_TASKS
    assert exempt.any? { |prefix| "current_scope:repair_schema".start_with?(prefix) },
           "the repair task must be able to boot, or it could never run"
    # The `app:` spelling is handled by stripping that prefix before matching,
    # not by a second entry — so assert the BEHAVIOUR, not the list's contents.
    assert exempt.any? { |prefix| "app:current_scope:repair_schema".delete_prefix("app:").start_with?(prefix) },
           "and the same under the app: prefix an engine's host uses"
  end
end
