# Deliberately misconfigured: includes Context but defines no current_user.
class BareController < ActionController::Base
  include CurrentScope::Context

  def show
    head :ok
  end
end
