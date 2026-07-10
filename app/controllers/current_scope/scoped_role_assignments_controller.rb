module CurrentScope
  # Grants/revokes a role on ONE specific record. The record arrives as a
  # GlobalID so any host model works without engine-side configuration —
  # link here from a resource page with:
  #
  #   current_scope.new_scoped_role_assignment_path(resource_gid: record.to_gid)
  class ScopedRoleAssignmentsController < ApplicationController
    def new
      @assignment = ScopedRoleAssignment.new
      @resource = locate(params[:resource_gid])
      @subjects = CurrentScope.config.subject_class.constantize.order(:id)
      @roles = Role.order(:name)
    end

    def create
      subject = GlobalID::Locator.locate(params.expect(:subject_gid))
      resource = GlobalID::Locator.locate(params.expect(:resource_gid))
      role = Role.find(params.expect(:role_id))

      ScopedRoleAssignment.transaction do
        ScopedRoleAssignment.create!(subject: subject, resource: resource, role: role)
        Event.record!(event: "scoped_role.granted", target: subject,
                      details: { role: role.name, resource: helpers.current_scope_label(resource) })
      end
      redirect_to subjects_path, notice: "Scoped role granted."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to subjects_path, alert: e.message
    end

    def destroy
      assignment = ScopedRoleAssignment.find(params[:id])
      subject, role, resource = assignment.subject, assignment.role, assignment.resource

      ScopedRoleAssignment.transaction do
        assignment.destroy!
        Event.record!(event: "scoped_role.revoked", target: subject,
                      details: { role: role.name, resource: helpers.current_scope_label(resource) })
      end
      redirect_to subjects_path, notice: "Scoped role revoked."
    end

    private

    def locate(gid)
      GlobalID::Locator.locate(gid) if gid.present?
    end
  end
end
