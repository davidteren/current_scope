class ExpenseClaimsController < ApprovableRecordsController
  private
    def record_params
      params.expect(expense_claim: [ :description, :amount ])
    end

    def initiator_association = :submitted_by
end
