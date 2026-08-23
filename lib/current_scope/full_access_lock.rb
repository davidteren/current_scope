module CurrentScope
  # Shared last-holder rule for the management UI and role-definition apply.
  # Holders, not spare unassigned full-access role rows.
  module FullAccessLock
    module_function

    # Serialize demote/delete/apply against concurrent last-holder removal.
    # Lock FA role rows and their org-wide holder assignments by id (FOR UPDATE
    # + join is adapter-fragile). Pass the role names a definitions document
    # plans to make full_access: a role the document PROMOTES is not full_access
    # yet, so the queries below cannot see it or its holders. Ordered by id, so
    # two concurrent applies take the rows in the same order. Call only inside a
    # transaction.
    def lock_console_state!(planned_fa_names = [])
      Role.where(full_access: true).or(Role.where(name: planned_fa_names)).order(:id).lock.load
      ids = RoleAssignment.joins(:role)
        .where(current_scope_roles: { full_access: true })
        .pluck(:id)
      ids |= RoleAssignment.joins(:role)
        .where(current_scope_roles: { name: planned_fa_names })
        .pluck(:id)
      RoleAssignment.where(id: ids).order(:id).lock.load if ids.any?
    end

    # True when at least one of these assignments still resolves to a live
    # subject. A row pointing at a deleted or unresolvable subject is not a
    # holder: nobody can open the console with it, so it must not vouch for the
    # console staying open, and it must not block a cleanup either. `any?` stops
    # at the first live holder, so a widely held role costs one subject lookup
    # rather than one per row.
    def live_holder?(assignments)
      assignments.any? do |assignment|
        # STRICT on purpose, unlike every other reader. current_scope_resolved_record
        # degrades a registry failure to nil (#166), which for a labeling caller is
        # right and for a guard is a lie: it would report "nobody holds full access"
        # when the truth is "this process cannot tell". Look the token up through the
        # raising path first, so a collision reaches the rescue in the two callers
        # below instead of being read as an inert row.
        CurrentScope.polymorphic_class(assignment.subject_type)
        assignment.current_scope_resolved_record("subject")
      end
    end
    private_class_method :live_holder?

    # True when this process cannot tell who holds what. A poisoned registry
    # resolves no subject, so every holder reads inert and the honest answer to
    # "does anyone still hold full access" is "unknown", not "nobody". The console
    # now RENDERS in that state (#166) rather than 500ing, so an operator can
    # reach the delete and demote paths, and these guards have to refuse there.
    # Checks the process-wide latch and the per-request marker, because the
    # second raise path (a live constant disagreeing with the registered owner)
    # never latches.
    def registry_blind?
      PolymorphicRegistry.error.present? ||
        CurrentScope::Current.polymorphic_registry_error.present?
    end
    private_class_method :registry_blind?

    # True when removing/demoting this full_access role would leave zero
    # full_access org holders. An unassigned full_access role is always safe.
    def would_lock_console_by_removing_role?(role)
      return true if registry_blind?
      return false unless role.full_access?
      return false unless live_holder?(RoleAssignment.where(role: role))

      !live_holder?(
        RoleAssignment.joins(:role)
          .where(current_scope_roles: { full_access: true })
          .where.not(role_id: role.id)
      )
    rescue CurrentScope::ConfigurationError
      # The second raise path never latches, so registry_blind? cannot see it
      # before the scan starts. Refuse: unknown is not "nobody".
      true
    end

    def held_full_access?
      live_holder?(RoleAssignment.joins(:role).where(current_scope_roles: { full_access: true }))
    end

    # True when the live world has a held full-access org role and the planned
    # name set would not. Planned names are document role names that stay
    # (or become) full_access — including a currently non-FA role that the
    # document promotes, whose live holders would then keep the console open.
    def would_lose_held_full_access?(planned_fa_names)
      return true if registry_blind?
      return false unless held_full_access?

      !live_holder?(RoleAssignment.joins(:role).where(current_scope_roles: { name: planned_fa_names }))
    rescue CurrentScope::ConfigurationError
      # Same reason as the sibling guard above.
      true
    end
  end
end
