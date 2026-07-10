class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  # Signing in/out is part of authentication, not authorization.
  skip_before_action :current_scope_check!
  # ...and must also clear the read-only-while-impersonating gate: signing in
  # or out is exactly how an impersonated session ends.
  skip_before_action :current_scope_mutation_guard!
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.authenticate_by(params.permit(:email_address, :password))
      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: "Try another email address or password."
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end
end
