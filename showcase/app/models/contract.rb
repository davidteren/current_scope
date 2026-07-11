class Contract < ApplicationRecord
  include CurrentScope::Scopeable
  include Approvable

  belongs_to :raised_by, class_name: "User"

  validates :title, presence: true, length: { maximum: 120 }
  validates :counterparty, length: { maximum: 120 }
  validates :amount, numericality: true, allow_nil: true

  # SoD hook: whoever raised the contract can never be the one to approve it.
  def current_scope_initiator = raised_by

  def current_scope_label = "Contract ##{id} — #{title}"
end
