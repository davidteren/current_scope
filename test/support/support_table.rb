# Load-time DDL for the test-only subject tables (uuid_user.rb, identity_user.rb).
#
# Built at LOAD time, before any test transaction opens: MySQL cannot run DDL
# inside a transaction, and the suite runs on all three adapters (bin/db).
#
# The table is created when missing and REBUILT only when its column names,
# column types, or index names no longer match the block. A table that matches
# is never touched, because every test process shares one database
# (storage/test.sqlite3 locally): when these were `force: true` a second
# process booting mid-run dropped the table under the first, which errored
# with "no such table" in 50 tests. A never-dropped table, in turn, silently
# kept stale columns after a branch changed them; this is the middle path.
# The dummy test environment tells the schema dumper to ignore the
# current_scope_test_ prefix, so the persisted tables never reach db/schema.rb.
#
# A default id is :primary_key on the definition and the adapter's reflected
# abstract type on the live column: :integer on SQLite, :bigint on MySQL and
# PostgreSQL. That pair is one token, not drift. Index identity is the name
# create_table would assign.
#
# ponytail: names, abstract types, and those index names are the drift signal.
# A limit, null, or default change, and a uniqueness change that keeps the
# index name, still needs `bin/rails db:test:prepare`.
module SupportTable
  def self.prepare(name, **options, &block)
    conn = ActiveRecord::Base.connection
    # Derived from the block, not restated by the caller: a list that drifted
    # from the block would never match and drop the table on every boot, which
    # is the race this module exists to close.
    definition = conn.build_create_table_definition(name, **options, &block)
    conn.drop_table(name, if_exists: true) if conn.table_exists?(name) && drifted?(conn, name, definition)
    conn.create_table(name, if_not_exists: true, **options, &block)
  end

  def self.drifted?(conn, name, definition)
    column_identity(definition, conn) != live_column_identity(conn, name) ||
      index_identity(conn, name, definition) != conn.indexes(name).map(&:name).sort
  end

  def self.column_identity(definition, conn)
    definition.columns.map { |column| [ column.name, type_token(column, conn) ] }.sort
  end

  def self.live_column_identity(conn, name)
    conn.columns(name).map { |column| [ column.name, column.type ] }.sort
  end

  # :primary_key is the definition's token for a default id. The live column
  # reports the abstract type the adapter reflected, never that symbol.
  def self.type_token(column, conn)
    return default_id_type(conn) if column.type == :primary_key

    column.type
  end

  def self.default_id_type(conn)
    /mysql|postgre/i.match?(conn.adapter_name) ? :bigint : :integer
  end

  def self.index_identity(conn, name, definition)
    definition.indexes.map { |column_name, index_options|
      conn.add_index_options(name, column_name, **index_options).first.name
    }.sort
  end
  private_class_method :drifted?, :column_identity, :live_column_identity,
                       :type_token, :default_id_type, :index_identity
end
