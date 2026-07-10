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
      return false if record.nil?

      initiator_method = CurrentScope.config.initiator_method
      return false unless record.respond_to?(initiator_method)

      record.public_send(initiator_method) == subject
    end

    def scoped_grant?(subject:, permission:, record:)
      return false if record.nil? || record.new_record?

      held = Role.where(
        id: ScopedRoleAssignment.where(subject: subject, resource: record).select(:role_id)
      )
      held.where(full_access: true)
          .or(held.where(id: RolePermission.where(permission_key: permission).select(:role_id)))
          .exists?
    end
  end
end
