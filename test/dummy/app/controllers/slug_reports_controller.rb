# A member route with a CUSTOM param (`param: :slug`) and no
# current_scope_record hook. Keying member-detection on :id alone would read
# /slug_reports/:slug as a collection action and hand out an ungranted record.
class SlugReportsController < ApplicationController
  include CurrentScope::Guard

  def show
    render plain: Report.find_by!(title: params[:slug]).title
  end
end
