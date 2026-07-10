module CurrentScope
  # A named, editable bundle of permissions — a row, not a class. The same
  # role means the same permission set whether held org-wide or scoped to a
  # single record; only the reach differs.
  class Role < ApplicationRecord
    has_many :role_permissions, dependent: :delete_all
    has_many :role_assignments, dependent: :destroy
    has_many :scoped_role_assignments, dependent: :destroy

    validates :name, presence: true, uniqueness: true

    def grants?(permission_key)
      role_permissions.exists?(permission_key: permission_key)
    end

    def permission_keys
      role_permissions.pluck(:permission_key)
    end

    # Replaces the role's permission set with the given keys, dropping any
    # that aren't in the catalog (stale keys from removed controllers).
    def permission_keys=(keys)
      keys = Array(keys).uniq.select { |k| CurrentScope.catalog.include?(k) }
      transaction do
        role_permissions.delete_all
        role_permissions.insert_all(keys.map { |k| { permission_key: k } }) if keys.any?
      end
    end
  end
end
