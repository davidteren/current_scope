module CurrentScope
  # Sets (or clears) a subject's single org-wide role.
  class RoleAssignmentsController < ApplicationController
    def create
      subjects = locate_subjects(submitted_subject_gids)
      if subjects.empty?
        redirect_back_or_to subjects_path, alert: "No subjects selected."
        return
      end

      clearing = params[:role_id].blank?

      # One transaction for the whole bulk action: the UI presents it as a single
      # operation, so a failure partway must not leave only the first subjects
      # changed. All-or-nothing across assignments and their audit events. Count
      # only the subjects that ACTUALLY changed so the notice can't over-report
      # (a re-set to the same role, or a clear on a subject with no role, is a
      # no-op and shouldn't be counted).
      changed = 0
      RoleAssignment.transaction do
        subjects.each do |subject|
          assignment = RoleAssignment.find_or_initialize_by(subject: subject)
          prior_role = assignment.role # nil for a brand-new assignment
          did = clearing ? clear_org_role(subject, assignment, prior_role) : set_org_role(subject, assignment, prior_role)
          changed += 1 if did
        end
      end

      # Return to wherever the action was invoked (the subjects page or a role's
      # members page); falls back to subjects when there's no referrer.
      redirect_back_or_to subjects_path, notice: org_notice(clearing, changed)
    rescue ActiveRecord::RecordNotFound, NameError
      redirect_back_or_to subjects_path, alert: "Couldn't set the org-wide role — a subject or role is no longer available."
    end

    # Remove ONE org-wide assignment by id — the path the members page uses to
    # clean up an orphaned assignment whose subject was deleted (the subject-keyed
    # clear on `create` can't target a subject that no longer resolves).
    def destroy
      assignment = RoleAssignment.find(params[:id])
      subject = resolve_subject(assignment)
      role_name = assignment.role.name

      RoleAssignment.transaction do
        assignment.destroy!
        Event.record!(event: "org_role.removed", target: subject || assignment, details: { role: role_name })
      end
      redirect_back_or_to subjects_path, notice: "Org-wide role removed."
    rescue ActiveRecord::RecordNotFound
      redirect_back_or_to subjects_path, notice: "That org-wide role was already removed."
    end

    private

    # The grantee, or nil when the subject was deleted or its type no longer
    # resolves (an orphaned assignment) — the ledger row then targets the
    # assignment itself rather than 500ing.
    def resolve_subject(assignment)
      assignment.subject
    rescue ActiveRecord::RecordNotFound, NameError
      nil
    end

    def org_notice(clearing, count)
      return "No org-wide role changes." if count.zero?

      verb = clearing ? "cleared" : "set"
      count == 1 ? "Org-wide role #{verb}." : "Org-wide role #{verb} for #{count} subjects."
    end

    # Returns true when a role was actually cleared, false when there was nothing
    # to clear (so the caller's count stays accurate).
    def clear_org_role(subject, assignment, prior_role)
      return false unless assignment.persisted? # nothing to clear ⇒ no event

      RoleAssignment.transaction do
        assignment.destroy!
        Event.record!(event: "org_role.removed", target: subject, details: { role: prior_role.name })
      end
      true
    end

    # Returns true when the subject's role actually changed, false on a no-op
    # re-set to the same role.
    def set_org_role(subject, assignment, prior_role)
      # Fetch the new role as its own object so `prior_role` (already loaded via
      # the association) isn't mistaken for it after the update.
      new_role = Role.find(params.expect(:role_id))
      changed = prior_role.nil? || prior_role.id != new_role.id

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
      changed
    end
  end
end
