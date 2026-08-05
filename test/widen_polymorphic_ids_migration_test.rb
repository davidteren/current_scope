require "test_helper"
require Rails.root.join("../../db/migrate/20260805000001_widen_current_scope_polymorphic_ids.rb")

# The #151 fix IS this migration, and nothing else ran it: the suite and CI both
# build from schema.rb, which already describes the widened columns. So the
# adapter branch, the PostgreSQL USING clause, the MySQL collation, the
# idempotence guard and the data-preserving cast were shipped untested — the same
# blind spot that let the original collision reach three releases.
#
# Runs on whichever adapter the suite is pointed at, so `bin/db test` exercises
# all three. Uses its own table rather than the real grant tables: those are
# already widened by the time the suite boots, and re-narrowing them mid-run
# would break every other test.
class WidenPolymorphicIdsMigrationTest < ActiveSupport::TestCase
  TABLE = :widen_migration_probe

  # DDL outside the test transaction — MySQL auto-commits it and would destroy
  # the savepoint (the same reason the UUID fixture builds its table at load).
  self.use_transactional_tests = false

  setup do
    connection.drop_table(TABLE, if_exists: true)
    # The PRE-migration shape: an integer id column, exactly as 0.2 to 0.4 shipped.
    connection.create_table(TABLE) do |t|
      t.string :subject_type, null: false
      t.integer :subject_id, null: false
    end
    connection.execute(
      "INSERT INTO #{connection.quote_table_name(TABLE)} " \
      "(subject_type, subject_id) VALUES ('User', 42)"
    )
  end

  teardown { connection.drop_table(TABLE, if_exists: true) }

  def connection = ActiveRecord::Base.connection

  def column = connection.columns(TABLE).find { |c| c.name == "subject_id" }

  # The migration targets the real tables by name, so drive its private widen on
  # the probe table instead. That is the method carrying every adapter branch.
  def widen!
    migration = WidenCurrentScopePolymorphicIds.new
    migration.verbose = false
    migration.send(:widen, TABLE, :subject_id)
  end

  test "an integer id column becomes a bounded string column" do
    assert_equal :integer, column.type, "precondition: the pre-migration shape"

    widen!

    assert_equal :string, column.type, "the whole point: a key is stored as a value"
    assert_equal CurrentScope::KEY_LIMIT, column.limit,
                 "bounded, or MySQL's five-column unique index exceeds its 3072-byte cap"
    assert_not column.null, "NOT NULL must survive the type change"
  end

  test "existing rows survive the cast rather than being dropped" do
    widen!

    stored = connection.select_value(
      "SELECT subject_id FROM #{connection.quote_table_name(TABLE)}"
    )
    assert_equal "42", stored.to_s,
                 "an integer key must come out the other side as its string form, " \
                 "not as NULL and not truncated"
  end

  test "running it twice is a no-op, so a re-run or a resumed migration is safe" do
    widen!
    assert_nothing_raised { widen! }

    assert_equal :string, column.type
    assert_equal CurrentScope::KEY_LIMIT, column.limit
  end

  test "the column compares case-sensitively — an identifier is not prose" do
    widen!

    connection.execute(
      "INSERT INTO #{connection.quote_table_name(TABLE)} " \
      "(subject_type, subject_id) VALUES ('User', 'ABC')"
    )
    lower = connection.select_value(
      "SELECT COUNT(*) FROM #{connection.quote_table_name(TABLE)} " \
      "WHERE subject_id = #{connection.quote('abc')}"
    ).to_i

    assert_equal 0, lower,
                 "MySQL's default collation is case AND accent insensitive, so \"ABC\" would " \
                 "match \"abc\" and a grant to one would reach the other — #151 by another " \
                 "route. The migration forces utf8mb4_bin for exactly this."
  end

  test "the migration refuses to run backwards rather than truncating keys" do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      WidenCurrentScopePolymorphicIds.new.migrate(:down)
    end
  end

  # The probe-table cases above drive `widen` directly. This one drives the actual
  # entry point against the actual grant tables, which is where the gap was: the
  # idempotence guard used to short-circuit on type and width alone, so a
  # schema-loaded database kept the server's case-insensitive collation and the
  # #151 collision stayed live. `up` is idempotent, so running it here is safe.
  test "up leaves every grant id and type column correct on this adapter" do
    WidenCurrentScopePolymorphicIds.new.tap { |m| m.verbose = false }.migrate(:up)

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
end
