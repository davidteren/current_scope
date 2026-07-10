# Ungated (Context only, no Guard) endpoint that echoes the ambient identity,
# so integration tests can observe how actor/user resolve inside a request.
class IdentityController < ApplicationController
  def show
    render json: {
      user: current_scope_user&.id,
      actor: current_scope_actor&.id,
      impersonating: impersonating?
    }
  end
end
