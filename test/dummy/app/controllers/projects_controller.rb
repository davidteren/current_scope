# The #50 escalation reproduction, at the request level. A collection-only
# controller declaring its type: without current_scope_model, a scoped grant
# held over some OTHER type (a Report) would have opened these gates —
# #index reads as an empty list, but #create has no list side to save it, so
# it was a live "create a Project off a Report grant" escalation.
class ProjectsController < ApplicationController
  include CurrentScope::Guard

  private

  # No member record here — these are collection actions.
  def current_scope_record = nil

  # The type the record-less gate binds to (#50).
  def current_scope_model = Project

  public

  def index
    render plain: scope_for(Project).order(:id).pluck(:name).join(",")
  end

  def create
    render plain: "created"
  end

  # #50 U6: proves the advisory path agrees with the gate. If the gate let the
  # request in, a bare allowed_to?(:index) rendered from the controller must be
  # true too — the view can never disagree with the gate on its own controller.
  def advisory
    render plain: allowed_to?(:index).to_s
  end
end
