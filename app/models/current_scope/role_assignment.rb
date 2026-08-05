module CurrentScope
  # A subject's single org-wide role. One per subject by design — the "which
  # role granted this?" ambiguity of multi-role systems is deliberately
  # avoided; per-record needs are covered by scoped roles instead.
  class RoleAssignment < ApplicationRecord
    belongs_to :role
    belongs_to :subject, polymorphic: true

    # One org-wide role per subject. Name the rule and the upsert alternative
    # so a double-grant is a one-line fix, not a trip through gem source (#44).
    # Base error (not :subject_id) so create! does not prefix "Subject id …".
    validate :one_org_role_per_subject
    # #151: refuse a subject whose primary key cannot survive the integer column.
    validate :subject_key_is_integer

    def one_org_role_per_subject
      return if subject_type.blank? || subject_id.blank?

      held = RoleAssignment.where(subject_type: subject_type, subject_id: subject_id)
      held = held.where.not(id: id) if persisted?
      existing = held.includes(:role).first
      return unless existing

      label = existing.role ? %("#{existing.role.name}") : "another role"
      errors.add(:base,
        "Subject already holds org-wide role #{label}; use CurrentScope.grant! " \
        "to replace, or scoped roles for additive access")
    end
    private :one_org_role_per_subject

    # Resolves from the TYPE COLUMN, not the association. On a row that is already
    # collapsed, `subject` resolves to nil (the id points at nothing), so reading
    # the association would return early and let CurrentScope.grant! re-escalate
    # the very row this guard exists for. The type column is set by the belongs_to
    # writer, so the new-record path is unchanged; safe_constantize returns nil for
    # a stale type, which is skipped exactly as a nil association was.
    def subject_key_is_integer
      klass = CurrentScope.polymorphic_class(subject_type, owner: self.class)
      return if klass.nil?
      # A write must fail CLOSED: if the key cannot be introspected we refuse
      # rather than store a value we cannot prove the column can hold.
      return if begin
        CurrentScope.integer_keyed?(klass)
      rescue StandardError
        false
      end

      errors.add(:base, CurrentScope.non_integer_key_error(klass, role: "subject"))
    end
    private :subject_key_is_integer

    # Bust the per-request org-role memo (CurrentScope::Current) whenever an
    # assignment changes, so a grant/clear and a later gate check in the SAME
    # request never disagree. after_save/after_destroy fire inside the
    # transaction, so this is correct under transactional tests too. The role's
    # own permission edits don't route through here, but they can't change which
    # role a subject holds — only the role_permissions, which the memo doesn't
    # cache (org_role caches the role object, whose grants? reads live).
    after_save    { CurrentScope::Current.reset_org_role_cache }
    after_destroy { CurrentScope::Current.reset_org_role_cache }
  end
end
