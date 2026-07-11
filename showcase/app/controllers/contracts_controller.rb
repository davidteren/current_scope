class ContractsController < ApprovableRecordsController
  private
    def record_params
      params.expect(contract: [ :title, :counterparty, :amount ])
    end

    def assign_initiator(record)
      record.raised_by = current_scope_user
    end
end
