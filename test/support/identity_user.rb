# A subject model with name + email, for #158 composite / email identity.
#
# Same load-time create_table pattern as UuidUser: MySQL cannot run DDL
# inside a test transaction. Prefixed table name so force: true cannot
# collide with a developer's real table.
class IdentityUser < ActiveRecord::Base
  self.table_name = "current_scope_test_identity_users"
end

ActiveRecord::Base.connection.create_table(IdentityUser.table_name, force: true) do |t|
  t.string :name
  t.string :email
  # A column the host has already unique-indexed, so the #158 boot check can
  # prove uniqueness from the index and run no scan at all. :email carries no
  # index and takes the LIMIT 1 duplicate probe instead.
  t.string :token, index: { unique: true }
end

Minitest.after_run do
  ActiveRecord::Base.connection.drop_table(IdentityUser.table_name, if_exists: true)
rescue StandardError
  nil
end
