# The conditional-skip residual WITH the tripwire included (U5 scenario 8):
# Guard is on, one action opts out via `only:`, and the tripwire must warn on
# exactly that action under :warn — the grid can't see this per-action hole,
# the runtime can. A dedicated twin of ConditionalSkipController, because
# including the tripwire THERE would raise (default :raise) inside
# gating_reflection_test's anonymous GET /conditional_skip.
class ConditionalSkipTripwireController < ApplicationController
  include CurrentScope::Guard
  include CurrentScope::GatingTripwire

  skip_before_action :current_scope_check!, only: :index, raise: false

  def index
    render plain: "conditional_skip_tripwire#index"
  end

  def show
    render plain: "conditional_skip_tripwire#show"
  end
end
