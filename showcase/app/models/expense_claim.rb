class ExpenseClaim < ApplicationRecord
  include CurrentScope::Scopeable
  include Approvable

  belongs_to :submitted_by, class_name: "User"

  validates :description, presence: true, length: { maximum: 200 }
  validates :amount, numericality: true, allow_nil: true

  # SoD hook: whoever submitted the claim can never be the one to approve it.
  def current_scope_initiator = submitted_by

  def current_scope_label = "Expense claim ##{id}"
end
