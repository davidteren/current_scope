# A NESTED COLLECTION (/projects/:project_id/nested_reports) that declares the
# hook and returns nil — the host stating "this action has no record", which is
# what lets a scoped-only subject reach it. The non-regression guard: a dynamic
# segment in the path (the parent's :project_id) must not stop a collection
# action being a collection action.
class NestedReportsController < ApplicationController
  include CurrentScope::Guard

  private

  # The one-line declaration a collection-only controller makes to opt its
  # gates into scoped grants.
  def current_scope_record = nil

  # The type this collection deals in (#50), threaded to the resolver as
  # model:. This controller is the shape the hook exists for — its route key
  # (nested_reports) is not the model's (reports), so nothing but a
  # declaration can name the type.
  def current_scope_model = Report

  public

  def index
    # Explicit key, not the derived one: this controller's path
    # (nested_reports) differs from the record's route key (reports), so
    # scope_for(Report) would ask about "reports#index" while the gate enforces
    # "nested_reports#index" — the key-drift foot-gun the README warns about.
    render plain: scope_for(Report, permission: "nested_reports#index").order(:id).pluck(:title).join(",")
  end
end
