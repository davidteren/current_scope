# Includes the tripwire but NOT Guard — the ungated case A4 must catch. #open
# trips the tripwire; #public_action is marked exempt via the mixin's own skip.
class TripwireUngatedController < ApplicationController
  include CurrentScope::GatingTripwire

  current_scope_skip_tripwire! only: :public_action

  def open
    head :ok
  end

  def public_action
    head :ok
  end
end
