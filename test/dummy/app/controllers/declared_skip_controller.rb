# #76 — whole-controller skip with a declared reason. Prefer this over bare
# skip_before_action so the role grid shows intent instead of an unexplained
# "gate not run" badge.
class DeclaredSkipController < ApplicationController
  include CurrentScope::Guard

  current_scope_skip_gate!(reason: "public health-check endpoint")

  def index
    render plain: "ok"
  end
end
