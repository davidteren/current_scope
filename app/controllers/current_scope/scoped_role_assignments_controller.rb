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
      ScopedRoleAssignment.create!(
        subject: GlobalID::Locator.locate(params.expect(:subject_gid)),
        resource: GlobalID::Locator.locate(params.expect(:resource_gid)),
        role_id: params.expect(:role_id)
      )
      redirect_to subjects_path, notice: "Scoped role granted."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to subjects_path, alert: e.message
    end

    def destroy
      ScopedRoleAssignment.find(params[:id]).destroy!
      redirect_to subjects_path, notice: "Scoped role revoked."
    end

    private

    def locate(gid)
      GlobalID::Locator.locate(gid) if gid.present?
    end
  end
end
