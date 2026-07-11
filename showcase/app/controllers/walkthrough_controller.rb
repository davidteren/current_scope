# The guided "try to commit fraud → refused" tour (U12). A narrative surface
# like the lobby: it skips the fail-closed gate and is excluded from the grid,
# so the role-less Visitor can complete it end to end. Every state change in the
# tour is a POST to a REAL endpoint (act-as, sign-in, approve) — the engine gate
# does the refusing, never this controller.
class WalkthroughController < ApplicationController
  skip_before_action :current_scope_check!

  STEPS = %w[intro prepared approve either].freeze

  # Wired to the seeded payroll personas: the preparer raises a run, the approver
  # signs it off. The target run is the one the preparer prepared.
  PREPARER_EMAIL = "payroll.preparer@example.com"
  APPROVER_EMAIL = "payroll.approver@example.com"

  def show
    @step = STEPS.include?(params[:step]) ? params[:step] : "intro"
    @preparer = User.find_by(email_address: PREPARER_EMAIL)
    @approver = User.find_by(email_address: APPROVER_EMAIL)
    @pay_run  = @preparer && PayRun.find_by(prepared_by: @preparer)

    # A sandbox reset (a later unit) can delete a visitor-created record or
    # persona mid-flow. Recover loudly — restart the tour — instead of 500ing.
    if @preparer.nil? || @approver.nil? || @pay_run.nil?
      flash.now[:alert] = "The sandbox was reset — restart the walkthrough."
      return render "reset"
    end

    render @step
  end
end
