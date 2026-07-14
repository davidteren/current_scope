module CurrentScope
  # A subject's single org-wide role. One per subject by design — the "which
  # role granted this?" ambiguity of multi-role systems is deliberately
  # avoided; per-record needs are covered by scoped roles instead.
  class RoleAssignment < ApplicationRecord
    belongs_to :role
    belongs_to :subject, polymorphic: true

    validates :subject_id, uniqueness: { scope: :subject_type }

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
