# #74: an SoD member action whose current_scope_record returns params[:id]
# (a String) — the veto is skipped (no new_record?), and the nudge must fire.
class SodStringController < ApplicationController
  include CurrentScope::Guard

  def approve
    head :ok
  end

  private

  def current_scope_record
    params[:id].presence || "42"
  end
end
