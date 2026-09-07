module CurrentScope
  # A named, editable bundle of permissions — a row, not a class. The same
  # role means the same permission set whether held org-wide or scoped to a
  # single record; only the reach differs.
  class Role < ApplicationRecord
    # #182: deleting a role is audited from here, so the console, a seed and a
    # console one-liner all leave the same row. The cascade below records its own
    # removals through each assignment's callback.
    #
    # CREATION is NOT here, and that asymmetry is deliberate rather than
    # forgotten: role.created carries the role's initial permission set, and the
    # role_permissions rows are not persisted yet when an after_create callback
    # runs. Emitting from after_commit instead would see them and would forfeit
    # the :strict rollback every other event in this file keeps. So a role
    # created by a seed leaves no row while its deletion does, and the
    # configuration guide says so (#182 review).
    include CurrentScope::AuditedWrites
    # The snapshot is taken BEFORE, because `dependent: :delete_all` on
    # role_permissions below is itself a before_destroy: by the time
    # after_destroy runs, permission_keys reads empty and the row would say the
    # deletion removed nothing. Declared above that association so it runs first
    # (#182 review).
    before_destroy :lock_for_destroy, prepend: true
    before_destroy :snapshot_for_audit
    after_destroy :record_role_deleted

    has_many :role_permissions, dependent: :delete_all
    has_many :role_assignments, dependent: :destroy
    has_many :scoped_role_assignments, dependent: :destroy

    validates :name, presence: true, uniqueness: true
    validate :permission_keys_in_catalog
    before_validation :lock_for_scoped_compatibility
    validate :held_scoped_grants_remain_compatible

    after_save :persist_permission_keys
    after_save :reset_cached_permissions
    after_destroy :reset_cached_permissions
    after_rollback :reset_cached_permissions

    # The grid diff computed by the last save:
    # { added: [...], removed: [...], rejected: [...] }. Empty arrays on a no-op
    # save; nil when no grid was staged (a programmatic save that never set
    # permission_keys). `added`/`removed` describe what actually persisted;
    # `rejected` names keys the scrub path threw away, so a caller that opted
    # into silence can still log it. Controllers read this to record the change
    # — the model itself records nothing (seeds must stay silent).
    attr_reader :permission_keys_change

    def grants?(permission_key)
      if stored_permissions_loaded?
        role_permissions.any? { |entry| entry.permission_key == permission_key.to_s }
      else
        role_permissions.exists?(permission_key: permission_key)
      end
    end

    def permission_keys
      return @pending_permission_keys unless @pending_permission_keys.nil?
      # Scoped validation must see the bundle that a new role will autosave.
      return role_permissions.map(&:permission_key) if new_record?

      stored_permission_keys
    end

    # Stages a replacement permission set. STRICT: a key that isn't in the
    # route-derived catalog makes the record invalid rather than disappearing.
    # This is the mass-assignment writer (update!, strong params, the role
    # grid), so it is deliberately the strict one — the scrub escape hatch must
    # never be reachable from form params.
    def permission_keys=(keys)
      assign_permission_keys(keys, scrub: false)
    end

    # ponytail: one implementation, two intents — the setter is the strict
    # front door, this is the same staging with the scrub opt-in named at the
    # call site.
    #
    # `scrub: true` is the ONLY sanctioned silent drop, and it exists for one
    # real case: a controller was removed, so a role still holds keys that no
    # longer route. Cleaning those up is legitimate and shouldn't require the
    # operator to name every dead key. Everything else — typos, unrouted
    # programmatic grants, the never-routed break-glass permission — is a
    # mistake, and a security-grant API must not swallow mistakes.
    def assign_permission_keys(keys, scrub: false)
      # Literal `true` only. Ruby truthiness would let the string "false" — or
      # any params/config value that found its way here — silently disable the
      # strict path, which is the exact hole this API exists to close. The
      # escape hatch opens for a caller that means it, not for one that passed
      # something along.
      @scrub_permission_keys = scrub == true
      # Blank entries are the grid's hidden-field padding, not typos (R2).
      @pending_permission_keys = Array(keys).map(&:to_s).reject(&:blank?).uniq
    end

    def reload(...)
      @pending_permission_keys = nil
      @scrub_permission_keys = false
      super
    end

    # Checks the proposed bundle without writing it. Join-row writes use the
    # same ceiling check as permission_keys= while holding the parent role lock.
    def incompatible_scoped_resource_class
      scoped_role_assignments.find_in_batches do |assignments|
        ScopedRoleAssignment.preload_resolvable_resources!(assignments)
        assignments.each do |assignment|
          klass = assignment.current_scope_governing_class
          if klass.respond_to?(:current_scope_grantable_permissions) &&
              !klass.current_scope_grantable_permissions.nil? &&
              !klass.current_scope_grants_role?(self)
            return klass
          end
        end
      end
      nil
    end

    private

    # The preload is safe only while its rows still represent saved data.
    # Do not discard the caller's drafts when a stored lookup is required.
    def stored_permissions_loaded?
      role_permissions.loaded? && role_permissions.all? { |entry| entry.persisted? && !entry.changed? }
    end

    def stored_permission_keys
      stored_permissions_loaded? ? role_permissions.pluck(:permission_key) : role_permissions.where(nil).pluck(:permission_key)
    end

    def lock_for_destroy
      FullAccessLock.lock_console_state!
    end

    def lock_for_scoped_compatibility
      self.class.where(id: id).lock.load if persisted?
    end

    def held_scoped_grants_remain_compatible
      return unless persisted?
      return unless full_access_changed? || !@pending_permission_keys.nil?

      klass = incompatible_scoped_resource_class
      if klass
        errors.add(:permission_keys, "cannot change while this role has scoped grants on #{klass.name}; remove incompatible grants first")
      end
    end

    def permission_keys_in_catalog
      return if @pending_permission_keys.nil? || @scrub_permission_keys

      unknown = @pending_permission_keys.reject { |k| CurrentScope.catalog.include?(k) }
      return if unknown.empty?

      errors.add(
        :permission_keys,
        "not in the permission catalog: #{unknown.join(', ')} — check for typos, or use " \
        "assign_permission_keys(..., scrub: true) to drop stale keys deliberately"
      )
    end

    def persist_permission_keys
      return if @pending_permission_keys.nil?

      # Capture the prior keys BEFORE delete_all so the diff survives the swap.
      previous = stored_permission_keys
      # Defense in depth: on the strict path validation already proved every key
      # is in the catalog, so this filter is a no-op. It is what the scrub path
      # relies on, and it means no future code path that skips validations
      # (insert_all, update_column, a bare `save(validate: false)`) can smuggle
      # an unknown key into the table.
      staged = @pending_permission_keys.select { |k| CurrentScope.catalog.include?(k) }
      @permission_keys_change = {
        added: staged - previous,
        removed: previous - staged,
        rejected: @pending_permission_keys - staged
      }

      role_permissions.delete_all
      role_permissions.insert_all(staged.map { |k| { permission_key: k } }) if staged.any?
      role_permissions.reset
      @pending_permission_keys = nil
      @scrub_permission_keys = false
    end

    def reset_cached_permissions
      role_permissions.reset
      CurrentScope::Current.reset_org_role_cache
    end

    def snapshot_for_audit
      return unless CurrentScope.config.audit

      # The PERSISTED rows, not `permission_keys`: that reader answers with
      # @pending_permission_keys when a caller has staged a replacement set
      # without saving it, and a destroy removes what is in the table. The row
      # must describe what the deletion actually took away (#182 review).
      @audit_snapshot = { name: name, full_access: full_access?,
                          permission_keys: stored_permission_keys }
    end

    # What the deletion REMOVED, not just its name: role.created and
    # role.updated both carry full_access and the permission set, and an auditor
    # reading only a name cannot tell what access went with it.
    def record_role_deleted
      audit_write!("role.deleted", target: self,
                                   details: @audit_snapshot || { name: name })
    end
  end
end
