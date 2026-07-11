class PayRunsController < ApprovableRecordsController
  private
    def record_params
      params.expect(pay_run: [ :period, :label, :amount ])
    end

    def assign_initiator(record)
      record.prepared_by = Current.user
    end
end
