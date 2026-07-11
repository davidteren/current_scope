class ContractsController < ApprovableRecordsController
  private
    def record_params
      params.expect(contract: [ :title, :counterparty, :amount ])
    end

    def initiator_association = :raised_by
end
