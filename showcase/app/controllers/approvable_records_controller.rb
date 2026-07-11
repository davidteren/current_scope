# Shared CRUD + the security-critical wiring for the three approval domains
# (pay runs, contracts, expense claims). The gate, the SoD record hook, the
# scope_for-driven index, and the approve action live here ONCE so every domain
# enforces them identically. Subclasses supply only strong params and the
# initiator column. Abstract — never routed, so it never appears in the grid.
class ApprovableRecordsController < ApplicationController
  before_action :set_record, only: %i[ show edit update destroy approve ]
  # Sandbox abuse bound: cap record creation and approvals. Mirrors the
  # sessions/passwords rate_limit precedent.
  rate_limit to: 20, within: 1.minute, only: %i[ create approve ],
    with: -> { redirect_to url_for(action: :index), alert: "Too many requests. Try again shortly." }

  # The list is keyed on #show (what you may open), not #index: reaching this
  # page needs the org #index grant, but the rows a scoped persona sees are
  # exactly the records their (scoped) #show grant covers. So a scoped approver
  # sees only their record while an org-wide approver sees all — the list/gate
  # agreement made visible (R29).
  def index
    @records = scope_for(model_class, permission: :show).order(:id)
  end

  def show
  end

  def new
    @record = model_class.new
  end

  def edit
  end

  def create
    @record = model_class.new(record_params)
    assign_initiator(@record)

    if @record.save
      redirect_to @record, notice: "#{model_class.model_name.human} was successfully created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def update
    if @record.update(record_params)
      redirect_to @record, notice: "#{model_class.model_name.human} was successfully updated.", status: :see_other
    else
      render :edit, status: :unprocessable_content
    end
  end

  def approve
    @record.approve!(by: current_scope_user)
    redirect_to @record, notice: "#{model_class.model_name.human} approved.", status: :see_other
  end

  def destroy
    @record.destroy!
    redirect_to url_for(action: :index), notice: "#{model_class.model_name.human} was successfully destroyed.", status: :see_other
  end

  private
    def model_class
      controller_name.classify.constantize
    end

    def set_record
      @record ||= model_class.find(params.expect(:id))
    end

    # Record-level authorization context for scoped roles and the SoD veto.
    # Loads eagerly (the gate runs before this controller's own callbacks) and
    # keys off path_parameters so a ?id= query string can't smuggle a record
    # into collection actions.
    def current_scope_record
      set_record if request.path_parameters[:id]
    end
end
