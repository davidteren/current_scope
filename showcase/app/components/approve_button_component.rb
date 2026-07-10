# The validation target for the ambient context: no current_user is passed
# in — the component asks the same resolver as the controller gate, via
# CurrentScope::Current. The button and the gate can never disagree.
class ApproveButtonComponent < ViewComponent::Base
  include CurrentScope::Permissions

  def initialize(report:)
    @report = report
  end

  attr_reader :report

  # Hidden when already approved, when the viewer lacks reports#approve, and
  # when the SoD veto applies (the requester viewing their own report).
  def render?
    !report.approved? && allowed_to?(:approve, report)
  end

  def call
    button_to "Approve", approve_report_path(report), class: "approve-button"
  end
end
