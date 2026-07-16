class ReportsController < ApplicationController
  include CurrentScope::Guard

  def index
    # scope_for, not Report.all — the gate decides whether this action runs, it
    # cannot filter the list. A scoped-only subject reaches this action (the
    # record-less gate), so an unscoped query here would hand them every report.
    # The dummy is the engine's worked example; it follows its own README.
    render plain: scope_for(Report).order(:id).pluck(:title).join(",")
  end

  def show
    render plain: report.title
  end

  def approve
    render plain: "approved #{report.title}"
  end

  def destroy
    report.destroy!
    head :no_content
  end

  private

  def report
    @report ||= Report.find(params[:id])
  end

  def current_scope_record
    report if request.path_parameters[:id]
  end

  # #50: the type this controller's collection actions list, so the record-less
  # gate can bind a scoped grant to it. Without this, a scoped-only subject's
  # #index would fail closed.
  def current_scope_model = Report
end
