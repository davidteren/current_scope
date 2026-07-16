# The R9 trap cell of the two-hook matrix (#50): current_scope_model declared
# while current_scope_record is NOT. The Guard passes NO_RECORD, the record-less
# branch never runs, and the declared type is never consulted — the model hook
# is silently inert. Exists so the inert-grant nudge's model clause has a
# request-level shape to fire against.
class InertModelController < ApplicationController
  include CurrentScope::Guard

  def index
    render plain: "inert"
  end

  # #50 review: proves the Guard does NOT stash the ambient model for the inert
  # (NO_RECORD) case — if it did, a view's allowed_to?(:index) would show a link
  # the gate denies. A full-access subject reaches it (full_access passes the
  # gate before the record-less branch); the stashed model must be nil.
  def ambient
    render plain: CurrentScope::Current.collection_model.inspect
  end

  private

  def current_scope_model = Report
end
