class ExpenseClaimsController < ApprovableRecordsController
  private
    def record_params
      params.expect(expense_claim: [ :description, :amount ])
    end

    def assign_initiator(record)
      record.submitted_by = current_scope_user
    end
end
