# A member route whose CUSTOM param ends in `_id` (`param: :external_id`), and
# no current_scope_record hook.
#
# This is the case that killed the last route-reading heuristic: "any path
# param not suffixed _id is this controller's record" reads :external_id as a
# nested parent, calls the request a collection action, and hands out an
# ungranted record. Keying off the hook's declaration instead makes the param's
# name irrelevant.
class ExternalIdReportsController < ApplicationController
  include CurrentScope::Guard

  def show
    render plain: Report.find_by!(title: params[:external_id]).title
  end
end
