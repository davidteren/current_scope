module CurrentScope
  class RolesController < ApplicationController
    def index
      @roles = Role.order(:name)
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

    def update
      @role = Role.find(params[:id])
      previous_name = @role.name
      saved = false
      Role.transaction do
        saved = @role.update(role_params)
        record_role_update(@role, previous_name) if saved
      end

      if saved
        redirect_to roles_path, notice: "Role updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      role = Role.find(params[:id])

      if last_full_access?(role)
        redirect_to roles_path,
                    alert: "Refusing to delete the last full-access role — it would lock everyone out of this UI."
        return
      end

      # Snapshot the cascade BEFORE destroy! — dependent: :destroy takes the
      # assignments with the role, so they can't be read afterwards.
      org_removed = role.role_assignments.includes(:subject).to_a
      scoped_revoked = role.scoped_role_assignments.includes(:subject, :resource).to_a

      Role.transaction do
        role.destroy!
        Event.record!(event: "role.deleted", target: role, details: { name: role.name })
        org_removed.each do |a|
          Event.record!(event: "org_role.removed", target: a.subject, details: { role: role.name })
        end
        scoped_revoked.each do |a|
          Event.record!(event: "scoped_role.revoked", target: a.subject,
                        details: { role: role.name, resource: helpers.current_scope_label(a.resource) })
        end
      end
      redirect_to roles_path, notice: "Role deleted."
    end

    private

    # One event per save: role.renamed when the name changed (carries old/new
    # name AND the grid diff), else role.updated for a pure grid change. Emits
    # nothing when neither the name nor the grid moved.
    def record_role_update(role, previous_name)
      diff = role.permission_keys_change || { added: [], removed: [] }
      renamed = previous_name != role.name
      return unless renamed || diff[:added].any? || diff[:removed].any?

      details = { added: diff[:added], removed: diff[:removed] }
      event = "role.updated"
      if renamed
        event = "role.renamed"
        details.merge!(old_name: previous_name, new_name: role.name)
      end
      Event.record!(event: event, target: role, details: details)
    end

    def last_full_access?(role)
      role.full_access? && !Role.where(full_access: true).where.not(id: role.id).exists?
    end

    def role_params
      permitted = params.expect(role: [ :name, :description, :full_access, permission_keys: [] ])
      # Grid group columns (CRUD checkboxes) submit "controller:group" tokens on
      # a separate, optional channel — permitted leniently so a raw permission_keys
      # post (no groups) still works. Expand them into action keys; the model's
      # permission_keys= dedups and drops anything not in the catalog.
      groups = params.fetch(:role, {}).permit(permission_groups: [])[:permission_groups]
      permitted[:permission_keys] = Array(permitted[:permission_keys]) + PermissionGrid.new.expand(groups)
      permitted
    end
  end
end
