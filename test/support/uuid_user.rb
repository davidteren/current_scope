# A subject model keyed on a string, for #151.
#
# Shared rather than defined inside one test file, because two suites need it:
# the resolver-level collision tests and the management-UI test that drives
# roles#members with a UUID-keyed subject_class. A second copy would mean two
# create_table calls racing over the same table.
#
# Built at LOAD time, before any test transaction opens. MySQL cannot run DDL
# inside a transaction — it auto-commits and the test's savepoint vanishes
# underneath it — and ActiveRecord's schema API is used rather than raw SQL
# because `id varchar PRIMARY KEY` is valid SQLite and a syntax error on MySQL.
# The suite runs on all three adapters (bin/db).
# The table name is prefixed and the class name is not. This loads for every
# test run, against whatever database DATABASE_URL points at, so it must not be
# able to collide with a table a developer actually has. It is `if_not_exists`
# and never dropped: every process shares storage/test.sqlite3, and when this
# was `force: true` a second test process (a system test file booting while
# `bin/rails test` ran) dropped the table under the first, which errored with
# "no such table" in 50 tests. If these columns change, run
# `bin/rails db:test:prepare` to rebuild the database. The dummy test
# environment tells the schema dumper to ignore the current_scope_test_ prefix,
# so the persisted tables never reach db/schema.rb. The CLASS keeps the short name because it is
# what lands in the polymorphic *_type column, where the tests read it.
class UuidUser < ActiveRecord::Base
  self.table_name = "current_scope_test_uuid_users"
end

ActiveRecord::Base.connection.create_table(UuidUser.table_name, id: :string, if_not_exists: true) do |t|
  t.string :name
end
