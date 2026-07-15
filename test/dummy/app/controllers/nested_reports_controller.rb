# A NESTED COLLECTION (/projects/:project_id/nested_reports). Its only dynamic
# segment is the parent's :project_id, so it must still read as a collection
# action and stay reachable by a scoped-only subject — the non-regression guard
# on member_route?.
class NestedReportsController < ApplicationController
  include CurrentScope::Guard

  def index
    # Explicit key, not the derived one: this controller's path
    # (nested_reports) differs from the record's route key (reports), so
    # scope_for(Report) would ask about "reports#index" while the gate enforces
    # "nested_reports#index" — the key-drift foot-gun the README warns about.
    render plain: scope_for(Report, permission: "nested_reports#index").order(:id).pluck(:title).join(",")
  end
end
