module CurrentScope
  # A subject's single org-wide role. One per subject by design — the "which
  # role granted this?" ambiguity of multi-role systems is deliberately
  # avoided; per-record needs are covered by scoped roles instead.
  class RoleAssignment < ApplicationRecord
    belongs_to :role
    belongs_to :subject, polymorphic: true

    def self.polymorphic_class_for(name)
      CurrentScope.polymorphic_class(name, owner: ActiveRecord::Base) ||
        raise(NameError, "unmapped polymorphic token #{name.inspect}")
    end

    # One org-wide role per subject. Name the rule and the upsert alternative
    # so a double-grant is a one-line fix, not a trip through gem source (#44).
    # Base error (not :subject_id) so create! does not prefix "Subject id …".
    validate :one_org_role_per_subject
    # #151: a grant must name exactly one record.
    include CurrentScope::StorableKeys
    validates_storable_polymorphic_keys "subject"

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
