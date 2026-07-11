class PayRun < ApplicationRecord
  include CurrentScope::Scopeable
  include Approvable

  belongs_to :prepared_by, class_name: "User"

  validates :period, presence: true, length: { maximum: 60 }
  validates :label, presence: true, length: { maximum: 120 }
  validates :amount, numericality: true, allow_nil: true

  # SoD hook: whoever prepared the run can never be the one to sign it off.
  def current_scope_initiator = prepared_by

  def current_scope_label = "Pay run ##{id} — #{label}"
end
