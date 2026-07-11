require "test_helper"
require_relative "../test_helpers/approval_domain_flow"

class ExpenseClaimsFlowTest < ActionDispatch::IntegrationTest
  include ApprovalDomainFlow

  private
    def prefix = "expense_claims"
    def param_key = :expense_claim
    def markup_field = :description
    def valid_attrs = { description: "Client dinner", amount: 220 }
end
