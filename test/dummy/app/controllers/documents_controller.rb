# The STI shape for #50's type bind, at the request level. Document is an STI
# base (Invoice < Document), so a scoped grant on an Invoice stores
# resource_type "Document" (the base_class) — and the gate must bind by
# base_class too, or a subclass-scoped subject 403s on the list that holds
# their rows (R6).
class DocumentsController < ApplicationController
  include CurrentScope::Guard

  private

  def document = @document ||= Document.find(params[:id])

  def current_scope_record
    document if request.path_parameters[:id]
  end

  def current_scope_model = Document

  public

  def index
    render plain: scope_for(Document).order(:id).pluck(:title).join(",")
  end

  def show
    render plain: document.title
  end
end
