# The validation target for the ambient context: no current_user is passed
# in — the component asks the same resolver as the controller gate, via
# CurrentScope::Current. The button and the gate can never disagree.
#
# Parameterized over any approvable record (reports, pay runs, contracts,
# expense claims): the approve path is derived from the record's route key, so
# one component serves every SoD domain.
class ApproveButtonComponent < ViewComponent::Base
  include CurrentScope::Permissions

  def initialize(record:)
    @record = record
  end

  attr_reader :record

  # Hidden when already approved, when the viewer lacks <record>#approve, and
  # when the SoD veto applies (the initiator viewing their own record).
  def render?
    !record.approved? && allowed_to?(:approve, record)
  end

  def call
    button_to "Approve", public_send("approve_#{record.model_name.singular_route_key}_path", record),
      class: "approve-button"
  end
end
