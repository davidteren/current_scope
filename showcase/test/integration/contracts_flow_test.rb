require "test_helper"
require_relative "../test_helpers/approval_domain_flow"

class ContractsFlowTest < ActionDispatch::IntegrationTest
  include ApprovalDomainFlow

  private
    def prefix = "contracts"
    def param_key = :contract
    def markup_field = :title
    def valid_attrs = { title: "Data processing addendum", counterparty: "Meridian Ltd", amount: 15_000 }
end
