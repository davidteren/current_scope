module CurrentScope
  # Sets (or clears) a subject's single org-wide role.
  class RoleAssignmentsController < ApplicationController
    def create
      subject = GlobalID::Locator.locate(params.expect(:subject_gid))
      assignment = RoleAssignment.find_or_initialize_by(subject: subject)
      prior_role = assignment.role # nil for a brand-new assignment

      if params[:role_id].blank?
        clear_org_role(subject, assignment, prior_role)
        redirect_to subjects_path, notice: "Org-wide role cleared."
      else
        set_org_role(subject, assignment, prior_role)
        redirect_to subjects_path, notice: "Org-wide role set."
      end
    end

    private

    def clear_org_role(subject, assignment, prior_role)
      return unless assignment.persisted? # nothing to clear ⇒ no event

      RoleAssignment.transaction do
        assignment.destroy!
        Event.record!(event: "org_role.removed", target: subject, details: { role: prior_role.name })
      end
    end

    def set_org_role(subject, assignment, prior_role)
      # Fetch the new role as its own object so `prior_role` (already loaded via
      # the association) isn't mistaken for it after the update.
      new_role = Role.find(params.expect(:role_id))

      RoleAssignment.transaction do
        assignment.update!(role: new_role)
        if prior_role.nil?
          Event.record!(event: "org_role.assigned", target: subject, details: { role: new_role.name })
        elsif prior_role.id != new_role.id
          Event.record!(event: "org_role.changed", target: subject,
                        details: { from: prior_role.name, to: new_role.name })
        end
        # same role re-set ⇒ no change ⇒ no event
      end
    end
  end
end
