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

      # One transaction for the writes. A denied recipient is skipped. Any other
      # failure still rolls the batch back, including its audit events. Count
      # only the subjects that ACTUALLY changed so the notice can't over-report
      # (a re-set to the same role, or a clear on a subject with no role, is a
      # no-op and shouldn't be counted).
      #
      # Lock full-access holders inside the same transaction as the writes so
      # concurrent clears cannot both observe "another holder remains" and then
      # both proceed to zero holders.
      changed = 0
      refused = false
      skipped = []
      RoleAssignment.transaction do
        # Host transactions can update recipients before granting access.
        # Take these locks first, in stable order, then roles and assignments.
        # Host load callbacks may leave defaults unsaved, so lock a fresh query
        # result instead of calling lock! on the located object. Use that
        # result for policy checks so changes before the lock are not missed.
        subjects = subjects.sort_by { |subject| [ subject.class.base_class.name, subject.id.to_s ] }.map do |subject|
          subject_class.lock.find(subject.id)
        end
        lock_full_access_org_holders!
        proposed = Role.includes(:role_permissions).lock.find(params.expect(:role_id)) unless clearing

        allowed = []
        subjects.each do |subject|
          previous = locked_role_for(RoleAssignment.lock.find_by(subject: subject))
          if assignment_allowed?(subject, previous:, proposed:, clearing:)
            allowed << subject
          else
            skipped << subject
          end
        end

        if allowed.empty?
          # Deny outside the skip path. Do not write, and do not continue.
          refuse_unmanaged_batch!(subjects, clearing:, proposed:)
        elsif would_remove_last_full_access_holders?(allowed, proposed: proposed)
          refused = true
        else
          allowed.each do |subject|
            assignment = RoleAssignment.lock.find_or_initialize_by(subject: subject)
            prior_role = locked_role_for(assignment) # nil for a brand-new assignment
            authorize_management!(:revoke_role, role: prior_role, target: subject) if prior_role || clearing
            did = clearing ? clear_org_role(subject, assignment, prior_role) : set_org_role(subject, assignment, prior_role, proposed)
            changed += 1 if did
          end
        end
      end

      if refused
        redirect_back_or_to subjects_path,
                            alert: full_access_refusal_alert("remove the last full-access org-wide assignment")
        return
      end

      # Return to wherever the action was invoked (the subjects page or a role's
      # members page); falls back to subjects when there's no referrer.
      redirect_back_or_to subjects_path, notice: org_notice(clearing, changed, skipped)
    rescue ActiveRecord::RecordNotFound, NameError
      redirect_back_or_to subjects_path, alert: "Couldn't set the org-wide role — a subject or role is no longer available."
    end

    # Remove ONE org-wide assignment by id — the path the members page uses to
    # clean up an orphaned assignment whose subject was deleted (the subject-keyed
    # clear on `create` can't target a subject that no longer resolves).
    def destroy
      refused = false
      RoleAssignment.transaction do
        assignment, subject = lock_assignment_for_revocation(RoleAssignment)
        assignment.role&.lock!
        authorize_management!(:revoke_role, role: assignment.role, target: subject)

        if FullAccessLock.would_lock_console_by_removing_assignment?(assignment)
          refused = true
        else
          # org_role.removed comes from RoleAssignment's own callback (#182), so
          # a seed or a rake task that destroys the row records it too.
          assignment.destroy!
        end
      end

      if refused
        redirect_back_or_to subjects_path,
                            alert: full_access_refusal_alert("remove the last full-access org-wide assignment")
        return
      end

      redirect_back_or_to subjects_path, notice: "Org-wide role removed."
    rescue ActiveRecord::StaleObjectError
      redirect_back_or_to subjects_path, alert: "That assignment changed. Reload the page and retry."
    rescue ActiveRecord::RecordNotFound
      redirect_back_or_to subjects_path, notice: "That org-wide role was already removed."
    end

    private

    # Each policy phase reads fresh stored role data. Fetch under the lock once,
    # rather than loading the association and immediately reloading it with lock!.
    def locked_role_for(assignment)
      return unless assignment&.role_id

      Role.uncached { Role.includes(:role_permissions).lock.find(assignment.role_id) }
    end

    # The notice shares the 4KB cookie session. Stop the skipped-name list
    # before that cookie can overflow after the writes have already committed.
    SKIPPED_NOTICE_BUDGET = 1_500
    NAME_CLIP_BYTES = 80

    def org_notice(clearing, count, skipped)
      base = if count.zero?
        "No org-wide role changes."
      else
        verb = clearing ? "cleared" : "set"
        count == 1 ? "Org-wide role #{verb}." : "Org-wide role #{verb} for #{count} subjects."
      end
      return base if skipped.empty?

      names = skipped.map { |subject| helpers.current_scope_subject_label(subject) }
      "#{base} #{skipped_names_sentence(names)}"
    end

    def skipped_names_sentence(names)
      kept = []
      names.each do |name|
        candidate = kept + [ name.to_s ]
        break if skipped_sentence(candidate, names.size - candidate.size).bytesize > SKIPPED_NOTICE_BUDGET

        kept = candidate
      end
      kept = [ clipped_notice_name(names.first) ] if kept.empty?
      skipped_sentence(kept, names.size - kept.size)
    end

    # A byte cut can split a character. The cookie session then refuses the
    # notice after the allowed change is already saved.
    def clipped_notice_name(name)
      text = name.to_s
      return text if text.bytesize <= NAME_CLIP_BYTES

      kept = +""
      text.each_char do |char|
        break if kept.bytesize + char.bytesize > NAME_CLIP_BYTES

        kept << char
      end
      kept
    end

    def skipped_sentence(kept, leftover)
      body = "Skipped #{kept.to_sentence}."
      leftover.positive? ? "#{body} And #{leftover} more." : body
    end

    # Literal true for every check the old loop raised on. A raised error is
    # not a skip: only a non-true answer drops that recipient.
    def assignment_allowed?(subject, previous:, proposed:, clearing:)
      if (previous || clearing) && CurrentScope.can_manage?(:revoke_role, role: previous, target: subject) != true
        return false
      end
      return true if clearing

      CurrentScope.can_manage?(:assign_role, role: proposed, target: subject) == true
    end

    def refuse_unmanaged_batch!(subjects, clearing:, proposed:)
      subject = subjects.first
      previous = locked_role_for(RoleAssignment.lock.find_by(subject: subject))
      authorize_management!(:revoke_role, role: previous, target: subject) if previous || clearing
      authorize_management!(:assign_role, role: proposed, target: subject) unless clearing
    end

    # True when applying clear (or reassign to a non-full_access role) to these
    # subjects would leave zero live full_access org holders. Orphan rows do
    # not count as remaining holders (#218).
    def would_remove_last_full_access_holders?(subjects, proposed:)
      return false if proposed&.full_access?

      holders = full_access_org_assignments.to_a
      affected = holders.select { |assignment| subjects.any? { |subject| same_subject?(assignment, subject) } }
      # Equivalent to would_lock_console_by_removing_assignments?([]) — kept so
      # the "no FA holder is being changed" case is visible at this call site.
      return false if affected.empty? # mutineer:disable-line

      FullAccessLock.would_lock_console_by_removing_assignments?(affected)
    end

    def full_access_org_assignments
      RoleAssignment.joins(:role).where(current_scope_roles: { full_access: true })
    end

    # Lock full-access holder rows (and their roles) so concurrent remove/demote
    # paths serialize on the same set the precheck reads. Call only inside a
    # transaction. Prefer locking by id after a join pluck — FOR UPDATE with
    # joins is adapter-fragile.
    def lock_full_access_org_holders!
      FullAccessLock.lock_console_state!
    end

    def same_subject?(assignment, subject)
      # Match the polymorphic storage name the subjects page uses (not only
      # base_class.name — hosts can customize polymorphic_name).
      # to_s on both: subject_id is a string column (#151) while a record keyed on
      # an integer answers 1, so a raw == silently never matches.
      assignment.subject_type == subject.class.polymorphic_name &&
        assignment.subject_id.to_s == subject.id.to_s
    end

    # Returns true when a role was actually cleared, false when there was nothing
    # to clear (so the caller's count stays accurate). Atomicity comes from
    # create's outer bulk transaction — only called from inside it. (No inner
    # transaction: without requires_new it would be a bare yield, and it isn't
    # wanted — a failure anywhere rolls back the whole batch by design.)
    def clear_org_role(subject, assignment, prior_role)
      return false unless assignment.persisted? # nothing to clear ⇒ no event

      # The event is the model's (#182).
      assignment.destroy!
      true
    end

    # Returns true when the subject's role actually changed, false on a no-op
    # re-set to the same role.
    def set_org_role(subject, assignment, prior_role, new_role)
      authorize_management!(:assign_role, role: new_role, target: subject)
      changed = prior_role.nil? || prior_role.id != new_role.id

      # Atomicity comes from create's outer bulk transaction (see clear_org_role).
      assignment.update!(role: new_role)
      # attribution on both, so every event in this family carries it
      # and an auditor filtering on it cannot silently lose a whole class of
      # change. The gate's own observation events are outside that family and
      # deliberately carry none (#182 review).
      if prior_role.nil?
        Event.record!(event: "org_role.assigned", target: subject,
                      details: { role: new_role.name, attribution: "actor" })
      elsif prior_role.id != new_role.id
        Event.record!(event: "org_role.changed", target: subject,
                      details: { from: prior_role.name, to: new_role.name, attribution: "actor" })
      end
      # same role re-set ⇒ no change ⇒ no event
      changed
    end
  end
end
