require_relative "support_table"

# A subject model keyed on a string, for #151.
#
# Shared rather than defined inside one test file, because two suites need it:
# the resolver-level collision tests and the management-UI test that drives
# roles#members with a UUID-keyed subject_class. A second copy would mean two
# create_table calls racing over the same table.
#
# ActiveRecord's schema API rather than raw SQL, because `id varchar PRIMARY
# KEY` is valid SQLite and a syntax error on MySQL. See SupportTable for why the
# table is built at load time and when it is rebuilt.
#
# The table name is prefixed and the class name is not. This loads for every
# test run, against whatever database DATABASE_URL points at, so it must not be
# able to collide with a table a developer actually has. The CLASS keeps the
# short name because it is what lands in the polymorphic *_type column, where
# the tests read it.
class UuidUser < ActiveRecord::Base
  self.table_name = "current_scope_test_uuid_users"
end

SupportTable.ensure(UuidUser.table_name, columns: %w[id name], id: :string) do |t|
  t.string :name
end
