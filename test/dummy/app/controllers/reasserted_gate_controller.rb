# The adoption guide's prescribed mitigation for an inherited skip (#62):
# re-assert the gate in the subclass. This child of the skipping base is
# properly gated again and must never be flagged as fail-open.
class ReassertedGateController < InheritedSkipBaseController
  before_action :current_scope_check!

  def index
    render plain: "reasserted_gate#index"
  end
end
