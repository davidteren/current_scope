module CurrentScope
  # The decision point. Every allow/deny question in the system routes through
  # here, in a fixed order:
  #
  #   1. SoD veto      — the record's initiator can never perform an SoD action
  #                      on it. Overrides everything, including full_access.
  #   2. full_access   — the subject's org-wide role grants all permissions,
  #                      present and future.
  #   3. org-wide role — the role's permission set includes this permission.
  #   4. scoped role   — a role held on THIS record grants the permission.
  #   5. default-deny  — nothing granted means denied.
  class Resolver
    INITIATOR_METHOD = :current_scope_initiator

    def allow?(subject:, permission:, record: nil)
      return false if subject.nil?
      return false if sod_veto?(subject: subject, permission: permission, record: record)

      role = org_role(subject)
      return true if role&.full_access?
      return true if role&.grants?(permission)

      scoped_grant?(subject: subject, permission: permission, record: record)
    end

    def org_role(subject)
      RoleAssignment.find_by(subject: subject)&.role
    end

    def full_access?(subject)
      !!(subject && org_role(subject)&.full_access?)
    end

    private

    def sod_veto?(subject:, permission:, record:)
      action = permission.split("#").last
      return false unless CurrentScope.config.sod_actions.include?(action)
      # No veto without an actual record instance (collection actions get nil,
      # class-form checks like allowed_to?(:approve, Report) get the class).
      return false unless record.respond_to?(:new_record?)

      # SoD is a structural guarantee — "cannot determine the initiator" must
      # never mean "permit". A record type where SoD genuinely doesn't apply
      # declares the hook returning nil.
      unless record.respond_to?(INITIATOR_METHOD, true)
        raise ConfigurationError,
              "#{record.class.name}##{INITIATOR_METHOD} is not defined, but " \
              "\"#{permission}\" is a separation-of-duties action (config.sod_actions). " \
              "Define #{INITIATOR_METHOD} on #{record.class.name} (return nil to exempt " \
              "a record), or remove \"#{action}\" from config.sod_actions."
      end

      initiator = record.send(INITIATOR_METHOD)
      initiator.present? && initiator == subject
    end

    def scoped_grant?(subject:, permission:, record:)
      # `record` may be a class (allowed_to?(:create, Report)) — classes can't
      # hold scoped grants, only persisted records can.
      return false unless record.respond_to?(:new_record?) && record.persisted?

      held = Role.where(
        id: ScopedRoleAssignment.where(subject: subject, resource: record).select(:role_id)
      )
      held.where(full_access: true)
          .or(held.where(id: RolePermission.where(permission_key: permission).select(:role_id)))
          .exists?
    end
  end
end
