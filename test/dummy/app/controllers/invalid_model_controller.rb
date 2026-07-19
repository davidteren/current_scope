# The 0.3.0 release-gate gap, at the request level: a controller that DID
# declare current_scope_model but returned something unusable — here a String,
# the classic typo (`"Report"` for `Report`). The resolver's shape guard
# refuses it, the deny is labelled :model_invalid (not :no_grant, and not
# :model_undeclared — claiming nothing was declared would be a lie), and the
# nudge names the value the hook actually returned.
class InvalidModelController < ApplicationController
  include CurrentScope::Guard

  def index
    render plain: "invalid"
  end

  private

  # Collection-only, opted into scoped grants — but the type is a String.
  def current_scope_record = nil
  def current_scope_model = "Report"
end
