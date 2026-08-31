module CurrentScope
  class RolesController < ApplicationController
    # #183: model declarations name roles BY NAME, so a rename moves them. The
    # warning only makes sense where a declaration exists — it is opt-in, and
    # for a host that has declared nothing the sentence would be false and the
    # task it points at would find nothing. (A type that includes GrantableRoles
    # WITHOUT Scopeable is not in this list; that is the one case it misses, and
    # it errs toward saying nothing.)
    #
    # On update too, or a rename that fails validation re-renders the form
    # without the warning — on the retry screen, which is the worst place to
    # lose it.
    before_action :assign_grantable_roles_declared, only: %i[edit update]
    def index
      # Includes for delete-confirm holder counts (cascade warning).
      @roles = Role.order(:name).includes(:role_assignments, :scoped_role_assignments)
    end

    def new
      @role = Role.new
    end

    def create
      @role = Role.new(role_params)
      saved = false
      Role.transaction do
        saved = @role.save
        # Fold the initial permission set into the create event — no separate
        # grid-diff event for a brand-new role.
        if saved
          Event.record!(event: "role.created", target: @role,
                        details: { name: @role.name, full_access: @role.full_access?,
                                   permission_keys: @role.permission_keys })
        end
      end

      if saved
        redirect_to edit_role_path(@role), notice: "Role created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @role = Role.find(params[:id])
    end

    # Who holds this role — the role-side complement to the subjects page. Org-wide
    # holders (this role IS their one org-wide role) and per-record scoped holders,
    # plus a capped list of subjects to add from here.
    ADD_LIMIT = 100

    def members
      @role = Role.find(params[:id])
      # No blanket polymorphic includes: stale subject_type/resource_type
      # NameErrors at preload. Org holders stay lazy; scoped resources use the
      # safe per-type preload (unresolvable types stay unloaded → inert label).
      @org_holders = RoleAssignment.where(role: @role).to_a
      @scoped_holders = ScopedRoleAssignment.where(role: @role).includes(role: :role_permissions).to_a
      ScopedRoleAssignment.preload_resolvable_resources!(@scoped_holders)

      # Still a subquery, not a plucked array: every subject holds exactly one
      # org-wide role, so a default role is held by the WHOLE user table and a
      # plucked NOT IN would carry one bind per subject. The cast is what makes it
      # work now that subject_id is a string column (#151) while subject_class
      # keys on a bigint — PostgreSQL refuses that comparison outright rather than
      # coercing. Cast the candidate side, so the stored value is never altered.
      #
      # Filter the subquery on subject_type, not a plucked id list: every org
      # assignment whose type reverse-resolves onto this subject table counts, not
      # only subject_class.polymorphic_name, so an STI or custom-token holder is
      # still excluded (#155). The token set is bounded by the model classes
      # sharing this base class — a few binds — where a subject_id list would carry
      # one bind per held subject and blow SQLITE_MAX_VARIABLE_NUMBER on a default
      # role held by the whole user table.
      held_types = RoleAssignment.subject_types_for(@org_holders, subject_class)
      remaining = subject_class.order(:id)
      if held_types.any?
        held = RoleAssignment.where(role: @role, subject_type: held_types).select(:subject_id)
        remaining = remaining.where.not(
          Arel::Nodes::In.new(candidate_key_as_text, held.arel.ast)
        )
      end
      @candidates = remaining.limit(ADD_LIMIT).to_a
      @more_candidates = remaining.offset(ADD_LIMIT).exists?
      @no_subjects = @candidates.empty? && !subject_class.exists?
    end

    def update
      permitted = role_params
      previous_name = nil
      saved = false
      refused = false

      # Lock full-access roles + holders inside the write transaction so two
      # concurrent demotions of the last held full-access roles cannot both pass
      # a pre-transaction check and then both commit.
      Role.transaction do
        # Lock FA console state before the target role so concurrent demote/delete
        # of two FA roles cannot invert lock order (roles first, then assignments).
        lock_full_access_console_state!
        @role = Role.lock.find(params[:id])

        if demoting_would_lock_console?(@role, permitted)
          refused = true
        else
          previous_name = @role.name
          previous_full_access = @role.full_access?
          saved = @role.update(permitted)
          record_role_update(@role, previous_name, previous_full_access) if saved
        end
      end

      if refused
        redirect_to edit_role_path(@role), alert: full_access_refusal_alert("remove full access from this role")
        return
      end

      if saved
        redirect_to roles_path, notice: "Role updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      refused = false

      Role.transaction do
        lock_full_access_console_state!
        role = Role.lock.find(params[:id])

        if would_lock_console_by_removing_role?(role)
          refused = true
        else
          # Snapshot WITHOUT polymorphic includes — includes(:subject)/:resource
          # can raise NameError for stale types at preload (members page avoids
          # this for the same reason). Resolve each row inside the helpers.
          org_removed = role.role_assignments.to_a
          scoped_revoked = role.scoped_role_assignments.to_a

          role.destroy!
          Event.record!(event: "role.deleted", target: role, details: { name: role.name })
          org_removed.each do |a|
            Event.record!(event: "org_role.removed", target: cascade_subject(a), details: { role: role.name })
          end
          scoped_revoked.each do |a|
            Event.record!(event: "scoped_role.revoked", target: cascade_subject(a),
                          details: { role: role.name, resource: cascade_resource_label(a) })
          end
        end
      end

      if refused
        redirect_to roles_path, alert: full_access_refusal_alert("delete this full-access role")
        return
      end

      redirect_to roles_path, notice: "Role deleted."
    end

    private

    def assign_grantable_roles_declared
      @grantable_roles_declared =
        CurrentScope.scopeable_resources.any? { |klass| klass.try(:current_scope_declares_roles_anywhere?) }
    end

    # Polymorphic subject/resource may be deleted or unresolvable — never 500
    # the cascade audit. Deleted records return nil without raising (especially
    # after includes preload), so use || assignment, not rescue-only.
    def cascade_subject(assignment)
      assignment.current_scope_resolved_record("subject") || assignment
    end

    def cascade_resource_label(assignment)
      resource = assignment.current_scope_resolved_record("resource")
      return "#{assignment.resource_type}##{assignment.resource_id}" if resource.nil?

      helpers.current_scope_label(resource)
    rescue StandardError
      "#{assignment.resource_type}##{assignment.resource_id}"
    end

    # One event per save: role.renamed when the name changed (carries old/new
    # name AND the grid/full_access diff), else role.updated. Emits nothing on
    # a pure no-op (same name, same grid, same full_access).
    def record_role_update(role, previous_name, previous_full_access)
      diff = role.permission_keys_change || { added: [], removed: [], rejected: [] }
      renamed = previous_name != role.name
      full_access_changed = previous_full_access != role.full_access?
      return unless renamed || full_access_changed || diff[:added].any? || diff[:removed].any?

      details = { added: diff[:added], removed: diff[:removed] }
      if full_access_changed
        details.merge!(full_access_from: previous_full_access, full_access_to: role.full_access?)
      end
      event = "role.updated"
      if renamed
        event = "role.renamed"
        details.merge!(old_name: previous_name, new_name: role.name)
      end
      Event.record!(event: event, target: role, details: details)
    end

    # The guard answers a bare true for two different reasons. Telling them apart
    # matters: "grant full access to another subject first" is useless advice when
    # the truth is that this process cannot read who holds it (#166).
    def full_access_refusal_alert(action)
      if CurrentScope::FullAccessLock.registry_blind?
        "Refusing to #{action} while the polymorphic registry is misconfigured: this " \
          "process cannot tell which subjects still hold full access. Fix the registry, " \
          "then retry."
      else
        "Refusing to #{action} — it is the last full access any subject holds and would " \
          "lock everyone out of this UI. Grant full access to another subject first, " \
          "then retry."
      end
    end

    # True when removing/demoting this full_access role would leave zero
    # full_access org holders. An unassigned full_access role is always safe
    # to delete/demote (cubic). An empty spare full_access role must NOT
    # authorize demoting the held Owner (CE) — check holders, not role rows.
    def would_lock_console_by_removing_role?(role)
      FullAccessLock.would_lock_console_by_removing_role?(role)
    end

    # True when the update would turn off full_access and lock the console.
    # Only treats an EXPLICIT full_access=false as demotion — a missing key
    # would not change the column and must not false-positive refuse.
    def demoting_would_lock_console?(role, permitted)
      return false unless role.full_access?
      return false unless permitted.key?(:full_access)
      return false if ActiveModel::Type::Boolean.new.cast(permitted[:full_access])

      would_lock_console_by_removing_role?(role)
    end

    # Serialize demote/delete against concurrent last-holder removal. Lock FA
    # role rows and their org-wide holder assignments (by id — FOR UPDATE + join
    # is adapter-fragile). Call only inside a transaction.
    def lock_full_access_console_state!
      FullAccessLock.lock_console_state!
    end

    # The candidate's primary key, rendered as text so it can be compared to the
    # string subject_id column (#151). Adapters differ twice over: MySQL spells the
    # cast CHAR where the others spell it TEXT, AND it refuses to compare two
    # different collations.
    #
    # The collation is READ FROM THE COLUMN rather than hardcoded, so this cannot
    # drift from what the migration set — and a host that chose a different binary
    # collation still works.
    def candidate_key_as_text
      connection = subject_class.connection
      column = "#{connection.quote_table_name(subject_class.table_name)}." \
               "#{connection.quote_column_name(subject_class.primary_key)}"
      return Arel.sql("CAST(#{column} AS TEXT)") unless CurrentScope.mysql?(connection)

      collation = RoleAssignment.columns_hash["subject_id"]&.collation
      raise ConfigurationError, "CurrentScope could not read subject_id's MySQL collation" if collation.blank?

      cast = "CAST(#{column} AS CHAR)"
      Arel.sql("#{cast} COLLATE #{collation}")
    end

    def role_params
      permitted = params.expect(role: [ :name, :description, :full_access, permission_keys: [] ])
      # Grid group columns (CRUD checkboxes) submit "controller:group" tokens on
      # a separate, optional channel — permitted leniently so a raw permission_keys
      # post (no groups) still works. Expand them into action keys; the model's
      # permission_keys= dedups, and REJECTS anything not in the catalog (the
      # save fails and `edit` re-renders with the error). The grid can't submit
      # such a key — cells are built from routed actions only — so a rejection
      # here means a hand-crafted request, which is worth saying out loud rather
      # than dropping silently.
      groups = params.fetch(:role, {}).permit(permission_groups: [])[:permission_groups]
      permitted[:permission_keys] = Array(permitted[:permission_keys]) + PermissionGrid.new.expand(groups)
      permitted
    end
  end
end
