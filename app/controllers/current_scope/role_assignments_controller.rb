module CurrentScope
  # Sets (or clears) a subject's single org-wide role.
  class RoleAssignmentsController < ApplicationController
    def create
      gids = Array(params[:subject_gids]).select(&:present?)
      gids = [ params[:subject_gid] ].compact if gids.empty?
      subjects = locate_subjects(gids)
      if subjects.empty?
        redirect_to subjects_path, alert: "No subjects selected."
        return
      end

      clearing = params[:role_id].blank?

      # One transaction for the whole bulk action: the UI presents it as a single
      # operation, so a failure partway must not leave only the first subjects
      # changed. All-or-nothing across assignments and their audit events.
      RoleAssignment.transaction do
        subjects.each do |subject|
          assignment = RoleAssignment.find_or_initialize_by(subject: subject)
          prior_role = assignment.role # nil for a brand-new assignment
          clearing ? clear_org_role(subject, assignment, prior_role) : set_org_role(subject, assignment, prior_role)
        end
      end

      redirect_to subjects_path, notice: org_notice(clearing, subjects.size)
    rescue ActiveRecord::RecordNotFound, NameError
      redirect_to subjects_path, alert: "Couldn't set the org-wide role — a subject or role is no longer available."
    end

    private

    def org_notice(clearing, count)
      verb = clearing ? "cleared" : "set"
      count == 1 ? "Org-wide role #{verb}." : "Org-wide role #{verb} for #{count} subjects."
    end

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
