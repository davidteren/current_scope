class Report < ApplicationRecord
  belongs_to :project, optional: true
  belongs_to :requested_by, class_name: "User"

  # SoD hook: whoever requested the report can never approve it.
  def current_scope_initiator
    requested_by
  end
end
