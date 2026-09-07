module CurrentScope
  # One granted controller#action for a role. The key mirrors a permission
  # auto-derived from the host's routes — there is no permissions table.
  class RolePermission < ApplicationRecord
    belongs_to :role

    validates :permission_key, presence: true, uniqueness: { scope: :role_id }

    validate :scoped_permissions_remain_compatible

    after_save :reset_cached_permissions
    after_destroy :reset_cached_permissions
    after_rollback :reset_cached_permissions

    private

    def scoped_permissions_remain_compatible
      return unless role&.persisted?

      candidate = Role.lock.find(role.id)
      # The parent lock does not invalidate an earlier cached sibling query.
      keys = self.class.uncached { candidate.role_permissions.where.not(id: id).pluck(:permission_key) }
      candidate.permission_keys = keys + [ permission_key ]
      klass = candidate.incompatible_scoped_resource_class
      errors.add(:permission_key, "exceeds the permission ceiling for #{klass.name}") if klass
    end

    def reset_cached_permissions
      association(:role).target&.role_permissions&.reset
      CurrentScope::Current.reset_org_role_cache
    end
  end
end
