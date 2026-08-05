# A subject model keyed on a string, for #151.
#
# Shared rather than defined inside one test file, because two suites need it:
# the resolver-level collision tests and the management-UI test that drives
# roles#members with a UUID-keyed subject_class. A second copy would mean two
# create_table(force: true) calls racing over the same table.
#
# Built at LOAD time, before any test transaction opens. MySQL cannot run DDL
# inside a transaction — it auto-commits and the test's savepoint vanishes
# underneath it — and ActiveRecord's schema API is used rather than raw SQL
# because `id varchar PRIMARY KEY` is valid SQLite and a syntax error on MySQL.
# The suite runs on all three adapters (bin/db).
ActiveRecord::Base.connection.create_table(:uuid_users, id: :string, force: true) do |t|
  t.string :name
end

class UuidUser < ActiveRecord::Base
  self.table_name = "uuid_users"
end

# Drop the table when the whole run ends, not per test: any later test that
# inspects ActiveRecord::Base.descendants or the table list would otherwise be
# order-dependent on this file having loaded.
Minitest.after_run do
  ActiveRecord::Base.connection.drop_table(:uuid_users, if_exists: true)
rescue StandardError
  nil
end
