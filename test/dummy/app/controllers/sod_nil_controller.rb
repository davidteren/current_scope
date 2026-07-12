# Deliberate A5 misuse: an SoD (approve) member action whose current_scope_record
# returns nil, so the SoD veto is silently skipped. Used to exercise the opt-in
# nudge.
class SodNilController < ApplicationController
  include CurrentScope::Guard

  def approve
    head :ok
  end

  private

  def current_scope_record
    nil
  end
end
