module CurrentScope
  # A subject's single org-wide role. One per subject by design — the "which
  # role granted this?" ambiguity of multi-role systems is deliberately
  # avoided; per-record needs are covered by scoped roles instead.
  class RoleAssignment < ApplicationRecord
    belongs_to :role
    belongs_to :subject, polymorphic: true

    validates :subject_id, uniqueness: { scope: :subject_type }
  end
end
