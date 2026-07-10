class ApplicationController < ActionController::Base
  include CurrentScope::Context

  private

  # Stand-in authentication for tests: the signed-in user comes from a header.
  def current_user
    User.find_by(id: request.headers["X-User-Id"])
  end
end
