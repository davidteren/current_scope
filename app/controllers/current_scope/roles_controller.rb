module CurrentScope
  class RolesController < ApplicationController
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
      # No polymorphic includes: eager-loading a stale/renamed subject_type or
      # resource_type raises NameError. Lazy-load per row and label defensively
      # in the view (current_scope_holder_* helpers), like the audit ledger does.
      @org_holders = RoleAssignment.where(role: @role).to_a
      @scoped_holders = ScopedRoleAssignment.where(role: @role).to_a

      # Exclude via a subquery, not a plucked Ruby array, so a role with many
      # holders doesn't build a huge NOT IN bind list.
      held = RoleAssignment.where(role: @role, subject_type: subject_class.name).select(:subject_id)
      remaining = subject_class.where.not(id: held).order(:id)
      @candidates = remaining.limit(ADD_LIMIT).to_a
      @more_candidates = remaining.offset(ADD_LIMIT).exists?
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
        @role = Role.lock.find(params[:id])
        lock_full_access_console_state!

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
        redirect_to edit_role_path(@role),
                    alert: "Refusing to remove full access — this is the last full-access role " \
                           "any subject holds and would lock everyone out of this UI. Grant " \
                           "full access to another subject first, then retry."
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
        role = Role.lock.find(params[:id])
        lock_full_access_console_state!

        if would_lock_console_by_removing_role?(role)
          refused = true
        else
          # Snapshot the cascade BEFORE destroy! — dependent: :destroy takes the
          # assignments with the role, so they can't be read afterwards.
          org_removed = role.role_assignments.includes(:subject).to_a
          scoped_revoked = role.scoped_role_assignments.includes(:subject, :resource).to_a

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
        redirect_to roles_path,
                    alert: "Refusing to delete this full-access role — it is the last one held by any " \
                           "subject and would lock everyone out of this UI. Grant full access to " \
                           "another subject first, then retry."
        return
      end

      redirect_to roles_path, notice: "Role deleted."
    end

    private

    # Polymorphic subject/resource may be deleted or unresolvable — never 500
    # the cascade audit (members page already resolves defensively).
    def cascade_subject(assignment)
      assignment.subject
    rescue ActiveRecord::RecordNotFound, NameError
      assignment
    end

    def cascade_resource_label(assignment)
      helpers.current_scope_label(assignment.resource)
    rescue ActiveRecord::RecordNotFound, NameError
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

    # True when removing/demoting this full_access role would leave zero
    # full_access org holders. An unassigned full_access role is always safe
    # to delete/demote (cubic). An empty spare full_access role must NOT
    # authorize demoting the held Owner (CE) — check holders, not role rows.
    def would_lock_console_by_removing_role?(role)
      return false unless role.full_access?
      return false unless RoleAssignment.where(role: role).exists?

      !RoleAssignment.joins(:role)
        .where(current_scope_roles: { full_access: true })
        .where.not(role_id: role.id)
        .exists?
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
      Role.where(full_access: true).lock.load
      ids = RoleAssignment.joins(:role)
        .where(current_scope_roles: { full_access: true })
        .pluck(:id)
      RoleAssignment.where(id: ids).lock.load if ids.any?
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
