module CurrentScope
  # A role held on ONE specific record: "Editor of Project #7" grants nothing
  # on Project #8. Never touches the subject's org-wide role — the two are
  # independent axes.
  class ScopedRoleAssignment < ApplicationRecord
    belongs_to :role
    belongs_to :subject, polymorphic: true
    belongs_to :resource, polymorphic: true

    validates :role_id, uniqueness: {
      scope: [ :subject_type, :subject_id, :resource_type, :resource_id ]
    }
  end
end
