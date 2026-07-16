# The #50 adoption gap, at the request level: a DECLARED collection action
# (current_scope_record = nil) on a controller that never declares
# current_scope_model. The record-less branch has no type to bind a scoped
# grant to, so a scoped-only subject is denied — with the distinct
# :model_undeclared reason (not :no_grant), and the
# warn_on_undeclared_collection_model nudge naming the one-line fix.
class UndeclaredModelController < ApplicationController
  include CurrentScope::Guard

  def index
    render plain: "undeclared"
  end

  private

  # Collection-only, opted into scoped grants — but the TYPE is missing.
  def current_scope_record = nil
end
