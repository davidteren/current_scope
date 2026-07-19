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
      #
      # Lock full-access holders inside the same transaction as the writes so
      # concurrent clears cannot both observe "another holder remains" and then
      # both proceed to zero holders.
      changed = 0
      refused = false
      RoleAssignment.transaction do
        lock_full_access_org_holders!

        if would_remove_last_full_access_holders?(subjects, clearing: clearing)
          refused = true
        else
          subjects.each do |subject|
            assignment = RoleAssignment.find_or_initialize_by(subject: subject)
            prior_role = assignment.role # nil for a brand-new assignment
            did = clearing ? clear_org_role(subject, assignment, prior_role) : set_org_role(subject, assignment, prior_role)
            changed += 1 if did
          end
        end
      end

      if refused
        redirect_back_or_to subjects_path,
                            alert: "Refusing to remove the last full-access org-wide assignment — " \
                                   "it would lock everyone out of this UI. Grant full access to " \
                                   "another subject first, then retry."
        return
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
      refused = false
      RoleAssignment.transaction do
        # Lock FA state BEFORE the target assignment so order matches create/
        # role demote/delete (FA roles → FA holders → target row). Locking the
        # assignment first inverted that order and could deadlock.
        lock_full_access_org_holders!
        assignment = RoleAssignment.lock.find(params[:id])
        subject = resolve_subject(assignment)
        role_name = assignment.role.name

        if last_full_access_org_assignment?(assignment)
          refused = true
        else
          assignment.destroy!
          Event.record!(event: "org_role.removed", target: subject || assignment, details: { role: role_name })
        end
      end

      if refused
        redirect_back_or_to subjects_path,
                            alert: "Refusing to remove the last full-access org-wide assignment — " \
                                   "it would lock everyone out of this UI. Grant full access to " \
                                   "another subject first, then retry."
        return
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

    # True when this assignment is a live full_access org holder and no other
    # full_access org assignment exists. Orphan rows (deleted subject → nil)
    # must not permanently block cleanup of the last FA assignment.
    def last_full_access_org_assignment?(assignment)
      return false unless assignment.role&.full_access?
      return false if resolve_subject(assignment).nil?

      !full_access_org_assignments.where.not(id: assignment.id).exists?
    end

    # True when applying clear (or reassign to a non-full_access role) to these
    # subjects would leave zero full_access org holders.
    def would_remove_last_full_access_holders?(subjects, clearing:)
      holders = full_access_org_assignments.to_a
      return false if holders.empty?

      affected_ids = holders.select { |a| subjects.any? { |s| same_subject?(a, s) } }.map(&:id)
      return false if affected_ids.empty?

      unless clearing
        new_role = Role.find_by(id: params[:role_id])
        return false if new_role&.full_access?
      end

      remaining = holders.reject { |a| affected_ids.include?(a.id) }
      remaining.empty?
    end

    def full_access_org_assignments
      RoleAssignment.joins(:role).where(current_scope_roles: { full_access: true })
    end

    # Lock full-access holder rows (and their roles) so concurrent remove/demote
    # paths serialize on the same set the precheck reads. Call only inside a
    # transaction. Prefer locking by id after a join pluck — FOR UPDATE with
    # joins is adapter-fragile.
    def lock_full_access_org_holders!
      Role.where(full_access: true).lock.load
      ids = full_access_org_assignments.pluck(:id)
      RoleAssignment.where(id: ids).lock.load if ids.any?
    end

    def same_subject?(assignment, subject)
      # Match the polymorphic storage name the subjects page uses (not only
      # base_class.name — hosts can customize polymorphic_name).
      assignment.subject_type == subject.class.polymorphic_name && assignment.subject_id == subject.id
    end

    # Returns true when a role was actually cleared, false when there was nothing
    # to clear (so the caller's count stays accurate). Atomicity comes from
    # create's outer bulk transaction — only called from inside it. (No inner
    # transaction: without requires_new it would be a bare yield, and it isn't
    # wanted — a failure anywhere rolls back the whole batch by design.)
    def clear_org_role(subject, assignment, prior_role)
      return false unless assignment.persisted? # nothing to clear ⇒ no event

      assignment.destroy!
      Event.record!(event: "org_role.removed", target: subject, details: { role: prior_role.name })
      true
    end

    # Returns true when the subject's role actually changed, false on a no-op
    # re-set to the same role.
    def set_org_role(subject, assignment, prior_role)
      # Fetch the new role as its own object so `prior_role` (already loaded via
      # the association) isn't mistaken for it after the update.
      new_role = Role.find(params.expect(:role_id))
      changed = prior_role.nil? || prior_role.id != new_role.id

      # Atomicity comes from create's outer bulk transaction (see clear_org_role).
      assignment.update!(role: new_role)
      if prior_role.nil?
        Event.record!(event: "org_role.assigned", target: subject, details: { role: new_role.name })
      elsif prior_role.id != new_role.id
        Event.record!(event: "org_role.changed", target: subject,
                      details: { from: prior_role.name, to: new_role.name })
      end
      # same role re-set ⇒ no change ⇒ no event
      changed
    end
  end
end
