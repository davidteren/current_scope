module CurrentScope
  # A named, editable bundle of permissions — a row, not a class. The same
  # role means the same permission set whether held org-wide or scoped to a
  # single record; only the reach differs.
  class Role < ApplicationRecord
    has_many :role_permissions, dependent: :delete_all
    has_many :role_assignments, dependent: :destroy
    has_many :scoped_role_assignments, dependent: :destroy

    validates :name, presence: true, uniqueness: true

    after_save :persist_permission_keys

    def grants?(permission_key)
      role_permissions.exists?(permission_key: permission_key)
    end

    def permission_keys
      @pending_permission_keys || role_permissions.pluck(:permission_key)
    end

    # Stages a replacement permission set, dropping keys that aren't in the
    # catalog (stale keys from removed controllers). Persisted on save, like
    # any other attribute — never before validations pass.
    def permission_keys=(keys)
      @pending_permission_keys = Array(keys).uniq.select { |k| CurrentScope.catalog.include?(k) }
    end

    def reload(...)
      @pending_permission_keys = nil
      super
    end

    private

    def persist_permission_keys
      return if @pending_permission_keys.nil?

      role_permissions.delete_all
      role_permissions.insert_all(@pending_permission_keys.map { |k| { permission_key: k } }) if @pending_permission_keys.any?
      @pending_permission_keys = nil
    end
  end
end
