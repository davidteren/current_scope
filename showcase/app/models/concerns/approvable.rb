# Shared approval lifecycle for the demo's SoD domains (pay runs, contracts,
# expense claims). approved_at is the source of truth for the stamp; status is
# the human-facing lifecycle label kept in step with it.
module Approvable
  extend ActiveSupport::Concern

  included do
    belongs_to :approved_by, class_name: "User", optional: true
  end

  def approved? = approved_at.present?

  def approve!(by:)
    update!(approved_by: by, approved_at: Time.current, status: "approved")
  end
end
