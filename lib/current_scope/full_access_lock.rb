module CurrentScope
  # Shared last-holder rule for the management UI and role-definition apply.
  # Holders, not spare unassigned full-access role rows.
  module FullAccessLock
    # One assignment-lock statement binds at most this many ids. Tests stub
    # the reader. This is not a host setting.
    ASSIGNMENT_LOCK_PAGE_SIZE = 100

    module_function

    def assignment_lock_page_size
      ASSIGNMENT_LOCK_PAGE_SIZE
    end

    # Serialize demote/delete against concurrent last-holder removal.
    # Lock all role rows, then current full-access holder assignments by id,
    # one page at a time. FOR UPDATE plus a join is adapter-fragile, so the
    # lock statement names ids only. The role set is small and stays one
    # statement, taken first so later assignment locks cannot invert it.
    # Grant controllers lock their recipient rows before entering this method.
    # Planned full-access names are not locked here. The would-lose walk locks
    # those ids on its own keyset. Ordered by id, so two concurrent callers
    # take the same rows in the same order. Call only inside a transaction.
    def lock_console_state!
      lock_role_rows!
      each_assignment_id_page(current_full_access_assignments) do |ids|
        lock_assignment_ids!(ids)
      end
    end

    # True when at least one of these assignments still resolves to a live
    # subject. A row pointing at a deleted or unresolvable subject is not a
    # holder: nobody can open the console with it, so it must not vouch for the
    # console staying open, and it must not block a cleanup either. `any?` stops
    # at the first live holder, so a widely held role costs one subject lookup
    # rather than one per row.
    def live_holder?(assignments)
      rows = assignments.to_a
      # STRICT on purpose, unlike every other reader, and once per DISTINCT token
      # rather than once per row. current_scope_resolved_record degrades a registry
      # failure to nil (#166), which for a labeling caller is right and for a guard
      # is a lie: it would report "nobody holds full access" when the truth is
      # "this process cannot tell". So ask the raising path first, and let a
      # collision reach the rescue in the two callers below.
      rows.map(&:subject_type).uniq.each { |type| CurrentScope.polymorphic_class(type) }

      rows.any? { |assignment| assignment.current_scope_resolved_record("subject") }
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

    # True when removing/demoting this full_access role would leave zero
    # full_access org holders. An unassigned full_access role is always safe.
    def would_lock_console_by_removing_role?(role)
      # full_access? FIRST: a non-full-access role cannot lock anyone out, so an
      # unrelated registry problem must not block ordinary role cleanup, and must
      # not report it as a last-full-access refusal.
      return false unless role.full_access?
      return true if registry_blind?
      return false unless live_holder?(RoleAssignment.where(role: role))

      !live_holder?(
        RoleAssignment.joins(:role)
          .where(current_scope_roles: { full_access: true })
          .where.not(role_id: role.id)
      )
    rescue CurrentScope::ConfigurationError => e
      # The second raise path never latches, so registry_blind? cannot see it
      # before the scan starts. Refuse: unknown is not "nobody". Record the cause
      # so registry_blind? answers true afterwards and the caller can say WHY it
      # refused instead of blaming a last full-access holder that may not exist.
      CurrentScope::Current.polymorphic_registry_error ||= e.message
      true
    end

    def held_full_access?
      live_holder?(RoleAssignment.joins(:role).where(current_scope_roles: { full_access: true }))
    end

    # True when a live full-access holder exists today and no planned name
    # would still have one. Planned names are document role names that stay
    # or become full_access, including a role the document promotes.
    #
    # Locks inside the caller's open transaction, in id order: every role row,
    # then current full-access assignment ids one page at a time, then
    # planned-name assignment ids on a separate keyset. A caller that only
    # needs the boolean must already be in that transaction.
    def would_lose_held_full_access?(planned_fa_names)
      walk_would_lose_held_full_access(planned_fa_names)
    end

    # True when destroying this org assignment would leave zero live full-access
    # holders. An orphan or unresolvable subject is not a live holder: cleanup
    # of that row is allowed, and the row must not vouch for the console.
    # Unknown (a registry failure while this row still resolves) is a refusal.
    def would_lock_console_by_removing_assignment?(assignment)
      return false unless assignment.role&.full_access?

      # Cause the failure we are testing for. A degrading read would make an
      # unlatched collision look like an orphan and allow the last live holder
      # to be removed. A stale token returns nil without raising (#90) and is
      # still cleanup, not unknown.
      CurrentScope.polymorphic_class(assignment.subject_type)
      return true if registry_blind?
      return false unless assignment.current_scope_resolved_record("subject")

      !live_holder?(remaining_full_access_assignments(except_ids: [ assignment.id ]))
    rescue CurrentScope::ConfigurationError => e
      CurrentScope::Current.polymorphic_registry_error ||= e.message
      true
    end

    # True when clearing or demoting these full-access assignments would leave
    # zero live full-access holders. Pass only the rows being changed.
    def would_lock_console_by_removing_assignments?(assignments)
      rows = Array(assignments)
      return false if rows.empty?

      rows.map(&:subject_type).uniq.each { |type| CurrentScope.polymorphic_class(type) }
      return true if registry_blind?

      !live_holder?(remaining_full_access_assignments(except_ids: rows.map(&:id)))
    rescue CurrentScope::ConfigurationError => e
      CurrentScope::Current.polymorphic_registry_error ||= e.message
      true
    end

    def remaining_full_access_assignments(except_ids:)
      RoleAssignment.joins(:role)
        .where(current_scope_roles: { full_access: true })
        .where.not(id: except_ids)
    end
    private_class_method :remaining_full_access_assignments

    def lock_role_rows!
      # Console writes are rare and the role set is small. Locking the whole
      # set before assignments prevents inversions in assignment cascades.
      Role.order(:id).lock.load
    end
    private_class_method :lock_role_rows!

    # Keyset on assignment id, not OFFSET. Two callers keep two cursors.
    # `break` from the block stops this walk, so a planned-name scan can
    # leave later pages unread after it has locked a live holder.
    def each_assignment_id_page(relation)
      after_id = nil
      loop do
        ids = assignment_id_page(relation, after_id)
        break if ids.empty?

        yield ids
        after_id = ids.last
      end
    end
    private_class_method :each_assignment_id_page

    def assignment_id_page(relation, after_id)
      column = RoleAssignment.arel_table[:id]
      scope = relation.unscope(:order).order(column.asc)
      scope = scope.where(column.gt(after_id)) unless after_id.nil?
      scope.limit(FullAccessLock.assignment_lock_page_size).pluck(column)
    end
    private_class_method :assignment_id_page

    def lock_assignment_ids!(ids)
      return [] if ids.empty?

      RoleAssignment.where(id: ids).order(:id).lock.to_a
    end
    private_class_method :lock_assignment_ids!

    def current_full_access_assignments
      RoleAssignment.joins(:role).where(current_scope_roles: { full_access: true })
    end
    private_class_method :current_full_access_assignments

    def planned_name_assignments(names)
      RoleAssignment.joins(:role).where(current_scope_roles: { name: names })
    end
    private_class_method :planned_name_assignments

    # Roles, then every current full-access id, then planned-name ids from
    # the lowest planned id. The current cursor is never reused as the
    # planned start. An id already locked is skipped in Ruby and still tested.
    def walk_would_lose_held_full_access(planned_fa_names)
      lock_role_rows!
      seen = {}
      each_assignment_id_page(current_full_access_assignments) do |ids|
        lock_assignment_ids!(ids)
        ids.each { |id| seen[id] = true }
      end

      # A blind registry cannot tell a live holder from an inert row.
      # Refuse before a planned page is allowed to answer that the console
      # stays open.
      return true if registry_blind?

      current_live = held_full_access?
      planned_live = false
      each_assignment_id_page(planned_name_assignments(planned_fa_names)) do |ids|
        # Not a NOT IN list: that list would put every current id into the
        # statement and remove the page bound.
        fresh = ids.reject { |id| seen.key?(id) }
        rows = lock_assignment_ids!(fresh)
        fresh.each { |id| seen[id] = true }
        missing = ids - rows.map(&:id)
        rows += RoleAssignment.where(id: missing).order(:id).to_a if missing.any?
        if live_holder?(rows)
          planned_live = true
          break
        end
      end

      return true if registry_blind?
      # A locked live planned holder stands. Do not read a later page, and
      # do not let a later check flip this answer.
      return false if planned_live

      current_live
    rescue CurrentScope::ConfigurationError => e
      # Same reason as the sibling guard above. Latch and return. Do not
      # raise: the apply caller still has to run the held-role delete check.
      CurrentScope::Current.polymorphic_registry_error ||= e.message
      true
    end
    private_class_method :walk_would_lose_held_full_access
  end
end
