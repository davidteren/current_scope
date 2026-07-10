class Report < ApplicationRecord
  belongs_to :project
  belongs_to :requested_by, class_name: "User"
  belongs_to :approved_by, class_name: "User", optional: true

  validates :title, presence: true

  def approved? = approved_at.present?

  def approve!(by:)
    update!(approved_by: by, approved_at: Time.current)
  end

  # SoD hook: whoever requested the report can never be the one to approve it.
  def current_scope_initiator
    requested_by
  end
end
