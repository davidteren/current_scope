require "test_helper"

# SupportTable builds the load-time support tables (test/support/uuid_user.rb,
# identity_user.rb), which persist between runs and are shared by every test
# process on one database. Driven here on a throwaway probe table, so the
# shared tables are never dropped by a test. Non-transactional: this runs real
# DDL, which MySQL auto-commits.
class SupportTablesTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PROBE = "current_scope_test_probe"
  # Default id, same call shape as IdentityUser, plus the unique token index.
  INDEXED = "current_scope_test_indexed"

  def connection = ActiveRecord::Base.connection

  def prepare_probe
    SupportTable.prepare(PROBE, id: :string) { |t| t.string :name }
  end

  def prepare_indexed
    SupportTable.prepare(INDEXED) do |t|
      t.string :name
      t.string :email
      t.string :token, index: { unique: true }
    end
  end

  def probe_columns = connection.columns(PROBE).map(&:name).sort

  def column_type(table, name)
    connection.columns(table).find { |column| column.name == name }.type
  end

  teardown do
    connection.drop_table(PROBE, if_exists: true)
    connection.drop_table(INDEXED, if_exists: true)
  end

  test "a missing table is created with the block's columns" do
    prepare_probe

    assert_equal %w[id name], probe_columns
  end

  test "a table whose columns drifted is rebuilt" do
    prepare_probe
    connection.add_column(PROBE, :stale, :string)

    prepare_probe

    assert_equal %w[id name], probe_columns,
      "if_not_exists alone would have kept the stale column until db:test:prepare"
  end

  # Names, not count: a renamed column keeps the count and must still rebuild.
  test "a table whose column was renamed is rebuilt" do
    prepare_probe
    connection.rename_column(PROBE, :name, :label)

    prepare_probe

    assert_equal %w[id name], probe_columns
  end

  test "a table that matches is left alone, rows included" do
    prepare_probe
    connection.execute("INSERT INTO #{connection.quote_table_name(PROBE)} (id, name) VALUES ('keep-me', 'Kept')")

    prepare_probe

    assert_equal 1, connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(PROBE)}").to_i,
      "a matching table must never be dropped: another test process may be using it"
  end

  test "a table whose column type drifted is rebuilt" do
    prepare_probe
    connection.change_column(PROBE, :name, :integer)

    prepare_probe

    assert_equal :string, column_type(PROBE, "name")
  end

  # A default id is :primary_key in the block and :integer (SQLite) or :bigint
  # (MySQL, PostgreSQL) on the live column. That pair is a match. Passing
  # id: :string would hide a false mismatch on the default.
  test "a matching default id table with an index is not dropped" do
    prepare_indexed
    quoted = connection.quote_table_name(INDEXED)
    connection.execute("INSERT INTO #{quoted} (name, email, token) VALUES ('Kept', 'kept@example.test', 'tok')")
    drops = 0
    original = connection.method(:drop_table)
    connection.define_singleton_method(:drop_table) do |*args, **kwargs|
      drops += 1
      original.call(*args, **kwargs)
    end

    prepare_indexed

    assert_equal 0, drops
    assert_equal 1, connection.select_value("SELECT COUNT(*) FROM #{quoted}").to_i
    assert_equal [ "index_#{INDEXED}_on_token" ], connection.indexes(INDEXED).map(&:name).sort
  ensure
    if connection.singleton_class.instance_methods(false).include?(:drop_table)
      connection.singleton_class.send(:remove_method, :drop_table)
    end
  end

  test "a table whose index name drifted is rebuilt" do
    prepare_indexed
    connection.rename_index(INDEXED, "index_#{INDEXED}_on_token", "current_scope_test_stale_index")

    prepare_indexed

    assert_equal [ "index_#{INDEXED}_on_token" ], connection.indexes(INDEXED).map(&:name).sort
  end

  # The real support tables persist, so a test-env db:migrate would dump them
  # into the tracked schema.rb unless the dumper is told to skip them.
  test "the support tables never reach schema.rb" do
    assert connection.table_exists?(UuidUser.table_name), "positive control: there is a table to ignore"
    io = StringIO.new
    ActiveRecord::SchemaDumper.dump(connection.pool, io)

    assert_empty io.string.scan(/create_table "current_scope_test_\w+"/),
      "test/dummy/config/environments/test.rb must ignore the current_scope_test_ prefix"
  end
end
