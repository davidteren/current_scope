# A subject model with name + email, for #158 composite / email identity.
#
# Same load-time create_table pattern as UuidUser: MySQL cannot run DDL
# inside a test transaction. Prefixed table name so it cannot collide with a
# developer's real table. `if_not_exists` and never dropped, for the reason in
# uuid_user.rb.
class IdentityUser < ActiveRecord::Base
  self.table_name = "current_scope_test_identity_users"
end

ActiveRecord::Base.connection.create_table(IdentityUser.table_name, if_not_exists: true) do |t|
  t.string :name
  t.string :email
  # A column the host has already unique-indexed, so the #158 boot check can
  # prove uniqueness from the index and never scan the table. :email carries no
  # index and takes the full GROUP BY duplicate scan instead (see #171).
  t.string :token, index: { unique: true }
end
