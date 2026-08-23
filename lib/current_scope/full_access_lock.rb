module CurrentScope
  # Shared last-holder rule for the management UI and role-definition apply.
  # Holders, not spare unassigned full-access role rows.
  module FullAccessLock
    module_function

    # Serialize demote/delete/apply against concurrent last-holder removal.
    # Lock FA role rows and their org-wide holder assignments by id (FOR UPDATE
    # + join is adapter-fragile). Call only inside a transaction.
    def lock_console_state!
      Role.where(full_access: true).lock.load
      ids = RoleAssignment.joins(:role)
        .where(current_scope_roles: { full_access: true })
        .pluck(:id)
      RoleAssignment.where(id: ids).lock.load if ids.any?
    end

    # True when removing/demoting this full_access role would leave zero
    # full_access org holders. An unassigned full_access role is always safe.
    def would_lock_console_by_removing_role?(role)
      return false unless role.full_access?
      return false unless RoleAssignment.where(role: role).exists?

      !RoleAssignment.joins(:role)
        .where(current_scope_roles: { full_access: true })
        .where.not(role_id: role.id)
        .exists?
    end

    def held_full_access?
      RoleAssignment.joins(:role)
        .where(current_scope_roles: { full_access: true })
        .exists?
    end

    # True when the live world has a held full-access org role and the planned
    # name set would not. Planned names are document role names that stay
    # (or become) full_access — including a currently non-FA role that the
    # document promotes, whose live holders would then keep the console open.
    def would_lose_held_full_access?(planned_fa_names)
      return false unless held_full_access?

      # Lock the planned holders as well. lock_console_state! covers roles that
      # are ALREADY full_access; a role this document PROMOTES is not in that
      # set, so its holders could be revoked between this check and the commit.
      # Same by-id shape, for the same adapter reason.
      ids = RoleAssignment.joins(:role)
        .where(current_scope_roles: { name: planned_fa_names })
        .pluck(:id)
      return true if ids.empty?

      RoleAssignment.where(id: ids).lock.load.empty?
    end
  end
end
