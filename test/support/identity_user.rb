require_relative "support_table"

# A subject model with name + email, for #158 composite / email identity.
#
# Same load-time pattern as UuidUser (see SupportTable). Prefixed table name so
# it cannot collide with a developer's real table.
class IdentityUser < ActiveRecord::Base
  self.table_name = "current_scope_test_identity_users"
end

SupportTable.prepare(IdentityUser.table_name) do |t|
  t.string :name
  t.string :email
  # A column the host has already unique-indexed, so the #158 boot check can
  # prove uniqueness from the index and never scan the table. :email carries no
  # index and takes the full GROUP BY duplicate scan instead (see #171).
  t.string :token, index: { unique: true }
end
