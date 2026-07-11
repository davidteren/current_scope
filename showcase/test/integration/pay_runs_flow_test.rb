require "test_helper"
require_relative "../test_helpers/approval_domain_flow"

class PayRunsFlowTest < ActionDispatch::IntegrationTest
  include ApprovalDomainFlow

  private
    def prefix = "pay_runs"
    def param_key = :pay_run
    def markup_field = :label
    def valid_attrs = { period: "2026-08", label: "August salaries", amount: 90_000 }
end
