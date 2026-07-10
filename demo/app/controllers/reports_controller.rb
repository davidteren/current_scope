class ReportsController < ApplicationController
  before_action :set_report, only: %i[ show edit update destroy approve ]

  def index
    @reports = Report.includes(:project, :requested_by, :approved_by).order(:id)
  end

  def show
  end

  def new
    @report = Report.new(project_id: params[:project_id])
  end

  def edit
  end

  def create
    @report = Report.new(report_params.merge(requested_by: Current.user))

    if @report.save
      redirect_to @report, notice: "Report was successfully created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @report.update(report_params)
      redirect_to @report, notice: "Report was successfully updated.", status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def approve
    @report.approve!(by: Current.user)
    redirect_to @report, notice: "Report approved.", status: :see_other
  end

  def destroy
    @report.destroy!
    redirect_to reports_path, notice: "Report was successfully destroyed.", status: :see_other
  end

  private
    def set_report
      @report ||= Report.find(params.expect(:id))
    end

    # Record-level authorization context for scoped roles and the SoD veto.
    # Loads eagerly: the gate runs before this controller's own callbacks.
    def current_scope_record
      set_report if params[:id]
    end

    def report_params
      params.expect(report: [ :title, :project_id ])
    end
end
