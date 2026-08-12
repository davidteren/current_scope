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

  # Coming from the integer column this migration was written for, nothing can be
  # too long. A host arriving from a WIDER string column is the case that matters:
  # MySQL outside strict mode narrows by truncating, silently, and a truncated key
  # names the wrong record — #151 caused by the migration meant to end it.
  test "it refuses to narrow a column holding a key that would not survive" do
    widen!
    connection.execute(
      "INSERT INTO #{connection.quote_table_name(TABLE)} " \
      "(subject_type, subject_id) VALUES ('User', #{connection.quote('a' * 10)})"
    )
    # Widen past the limit so there is room for an over-long value to exist.
    connection.change_column(TABLE, :subject_id, :string, limit: 200)
    connection.execute(
      "INSERT INTO #{connection.quote_table_name(TABLE)} " \
      "(subject_type, subject_id) VALUES ('User', #{connection.quote('x' * (CurrentScope::KEY_LIMIT + 1))})"
    )

    migration = WidenCurrentScopePolymorphicIds.new
    migration.verbose = false
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:refuse_if_any_key_too_long, TABLE, :subject_id)
    end
    assert_match(/1 value\(s\) longer than #{CurrentScope::KEY_LIMIT}/, error.message)
    assert_match(/truncated key names the WRONG record/, error.message)
  end

  test "it preflights text columns before narrowing them" do
    connection.change_column(TABLE, :subject_id, :text)
    connection.execute(
      "INSERT INTO #{connection.quote_table_name(TABLE)} " \
      "(subject_type, subject_id) VALUES ('User', #{connection.quote('x' * (CurrentScope::KEY_LIMIT + 1))})"
    )

    migration = WidenCurrentScopePolymorphicIds.new.tap { |item| item.verbose = false }
    assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.send(:refuse_if_any_key_too_long, TABLE, :subject_id)
    end
  end

  test "an otherwise-correct nullable column is repaired" do
    connection.change_column(TABLE, :subject_id, :string, limit: CurrentScope::KEY_LIMIT, null: true)

    widen!

    assert_not column.null
  end

  test "the migration refuses to run backwards rather than truncating keys" do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      WidenCurrentScopePolymorphicIds.new.migrate(:down)
    end
  end

  # Drive the PUBLIC entry point against a genuinely pre-migration table. The
  # old test pointed `up` at schema-loaded grant tables that already had the
  # asserted shape, so on SQLite/PostgreSQL deleting the real wiring stayed green.
  test "up transforms its declared id and type columns" do
    with_probe_as_migration_target do
      assert_equal :integer, column.type

      WidenCurrentScopePolymorphicIds.new.tap { |migration| migration.verbose = false }.migrate(:up)

      assert_equal :string, column.type
      assert_equal CurrentScope::KEY_LIMIT, column.limit
      assert_not column.null
      if CurrentScope.mysql?(connection)
        %w[subject_id subject_type].each do |name|
          info = connection.columns(TABLE).find { |candidate| candidate.name == name }
          assert info.collation.to_s.end_with?("_bin"), "#{name} must compare as an identifier"
        end
      end
    end
  end

  private

  def with_probe_as_migration_target
    migration = WidenCurrentScopePolymorphicIds
    original_columns = migration::COLUMNS
    original_type_columns = migration::TYPE_COLUMNS
    migration.send(:remove_const, :COLUMNS)
    migration.send(:remove_const, :TYPE_COLUMNS)
    migration.const_set(:COLUMNS, { TABLE => [ :subject_id ] }.freeze)
    migration.const_set(:TYPE_COLUMNS, { TABLE => [ :subject_type ] }.freeze)
    yield
  ensure
    migration.send(:remove_const, :COLUMNS)
    migration.send(:remove_const, :TYPE_COLUMNS)
    migration.const_set(:COLUMNS, original_columns)
    migration.const_set(:TYPE_COLUMNS, original_type_columns)
  end
end
