module CurrentScope
  # Sets (or clears) a subject's single org-wide role.
  class RoleAssignmentsController < ApplicationController
    def create
      subject = GlobalID::Locator.locate(params.expect(:subject_gid))
      assignment = RoleAssignment.find_or_initialize_by(subject: subject)

      if params[:role_id].blank?
        assignment.destroy if assignment.persisted?
        redirect_to subjects_path, notice: "Org-wide role cleared."
      else
        assignment.update!(role_id: params.expect(:role_id))
        redirect_to subjects_path, notice: "Org-wide role set."
      end
    end
  end
end
