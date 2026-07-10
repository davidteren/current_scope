module CurrentScope
  # One granted controller#action for a role. The key mirrors a permission
  # auto-derived from the host's routes — there is no permissions table.
  class RolePermission < ApplicationRecord
    belongs_to :role

    validates :permission_key, presence: true, uniqueness: { scope: :role_id }
  end
end
