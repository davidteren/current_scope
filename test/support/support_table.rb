# Load-time DDL for the test-only subject tables (uuid_user.rb, identity_user.rb).
#
# Built at LOAD time, before any test transaction opens: MySQL cannot run DDL
# inside a transaction, and the suite runs on all three adapters (bin/db).
#
# The table is created when missing and REBUILT only when its columns no longer
# match the block. A table that matches is never touched, because every test
# process shares one database (storage/test.sqlite3 locally): when these were
# `force: true` a second process booting mid-run dropped the table under the
# first, which errored with "no such table" in 50 tests. A never-dropped table,
# in turn, silently kept stale columns after a branch changed them; this is the
# middle path. The dummy test environment tells the schema dumper to ignore the
# current_scope_test_ prefix, so the persisted tables never reach db/schema.rb.
#
# ponytail: column NAMES are the drift signal; a type or index change still
# needs `bin/rails db:test:prepare`.
module SupportTable
  def self.prepare(name, **options, &block)
    conn = ActiveRecord::Base.connection
    # Derived from the block, not restated by the caller: a list that drifted
    # from the block would never match and drop the table on every boot, which
    # is the race this module exists to close.
    wanted = conn.build_create_table_definition(name, **options, &block).columns.map(&:name).sort
    if conn.table_exists?(name) && conn.columns(name).map(&:name).sort != wanted
      conn.drop_table(name, if_exists: true)
    end
    conn.create_table(name, if_not_exists: true, **options, &block)
  end
end
