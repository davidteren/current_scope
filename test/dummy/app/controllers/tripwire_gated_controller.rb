# Includes Guard AND the tripwire — a properly gated controller. current_scope_check!
# runs, so the tripwire must NOT trip.
class TripwireGatedController < ApplicationController
  include CurrentScope::Guard
  include CurrentScope::GatingTripwire

  def show
    head :ok
  end
end
