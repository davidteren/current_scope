module CurrentScope
  # One granted controller#action for a role. The key mirrors a permission
  # auto-derived from the host's routes — there is no permissions table.
  class RolePermission < ApplicationRecord
    belongs_to :role

    validates :permission_key, presence: true, uniqueness: { scope: :role_id }

    after_save :reset_cached_permissions
    after_destroy :reset_cached_permissions
    after_rollback :reset_cached_permissions

    private

    def reset_cached_permissions
      association(:role).target&.role_permissions&.reset
      CurrentScope::Current.reset_org_role_cache
    end
  end
end
