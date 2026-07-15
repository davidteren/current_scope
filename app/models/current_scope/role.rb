module CurrentScope
  # A named, editable bundle of permissions — a row, not a class. The same
  # role means the same permission set whether held org-wide or scoped to a
  # single record; only the reach differs.
  class Role < ApplicationRecord
    has_many :role_permissions, dependent: :delete_all
    has_many :role_assignments, dependent: :destroy
    has_many :scoped_role_assignments, dependent: :destroy

    validates :name, presence: true, uniqueness: true
    validate :permission_keys_in_catalog

    after_save :persist_permission_keys

    # The grid diff computed by the last save:
    # { added: [...], removed: [...], rejected: [...] }. Empty arrays on a no-op
    # save; nil when no grid was staged (a programmatic save that never set
    # permission_keys). `added`/`removed` describe what actually persisted;
    # `rejected` names keys the scrub path threw away, so a caller that opted
    # into silence can still log it. Controllers read this to record the change
    # — the model itself records nothing (seeds must stay silent).
    attr_reader :permission_keys_change

    def grants?(permission_key)
      role_permissions.exists?(permission_key: permission_key)
    end

    def permission_keys
      @pending_permission_keys || role_permissions.pluck(:permission_key)
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
      @scrub_permission_keys = scrub
      # Blank entries are the grid's hidden-field padding, not typos (R2).
      @pending_permission_keys = Array(keys).map(&:to_s).reject(&:blank?).uniq
    end

    def reload(...)
      @pending_permission_keys = nil
      @scrub_permission_keys = false
      super
    end

    private

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
      previous = role_permissions.pluck(:permission_key)
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
      @pending_permission_keys = nil
      @scrub_permission_keys = false
    end
  end
end
