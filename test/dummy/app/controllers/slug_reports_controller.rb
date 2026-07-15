# A member route with a CUSTOM param (`param: :slug`) and no
# current_scope_record hook — the controller declares nothing, so the gate must
# assume nothing.
#
# Pins that the fix does not depend on reading the route: every attempt to guess
# member-vs-collection from path parameters fails on some routing DSL option
# (`:id` misses `param: :slug`; "not suffixed _id" misses `param: :external_id`).
# Because the gate keys off the declaration instead, this route's shape is
# irrelevant — no hook, no scoped allow.
class SlugReportsController < ApplicationController
  include CurrentScope::Guard

  def show
    render plain: Report.find_by!(title: params[:slug]).title
  end
end
