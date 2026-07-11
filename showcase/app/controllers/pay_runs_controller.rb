class PayRunsController < ApprovableRecordsController
  private
    def record_params
      params.expect(pay_run: [ :period, :label, :amount ])
    end

    def initiator_association = :prepared_by
end
