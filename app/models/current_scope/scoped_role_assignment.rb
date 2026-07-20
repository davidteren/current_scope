module CurrentScope
  # A role held on ONE specific record: "Editor of Project #7" grants nothing
  # on Project #8. Never touches the subject's org-wide role — the two are
  # independent axes.
  #
  # Rows survive host resource destruction by design (polymorphic, no
  # dependent:). Since #65 those orphan grants open nothing (empty list = 403)
  # but still rendered like live access until labeled (#90).
  class ScopedRoleAssignment < ApplicationRecord
    belongs_to :role
    belongs_to :subject, polymorphic: true
    belongs_to :resource, polymorphic: true

    validates :role_id, uniqueness: {
      scope: [ :subject_type, :subject_id, :resource_type, :resource_id ]
    }

    # True when the pointed-at resource is gone (deleted row or unresolvable
    # type). The grant is inert for authorization (#65) but still a console row.
    def orphaned_resource?
      return false if resource_id.blank?

      # Reset so a resource deleted after this row was loaded is not still
      # cached as present (console would miss the inert state) — PR #104.
      association(:resource).reset
      resource.nil?
    rescue NameError, ActiveRecord::RecordNotFound
      true
    end
  end
end
