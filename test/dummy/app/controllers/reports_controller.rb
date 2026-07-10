class ReportsController < ApplicationController
  include CurrentScope::Guard

  def index
    render plain: Report.order(:id).pluck(:title).join(",")
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
    report if params[:id]
  end
end
