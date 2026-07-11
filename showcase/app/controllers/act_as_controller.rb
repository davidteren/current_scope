# The host owns the act-as switch — CurrentScope only reads it. Start/stop are
# POST/DELETE only (never GET links: SameSite=Lax makes a GET switch cross-site
# forceable). The controller is excluded from the permission catalog, so it
# skips the fail-closed gate.
class ActAsController < ApplicationController
  skip_before_action :current_scope_check!
  # Stopping act-as is a DELETE made WHILE impersonating; were the read-only
  # gate armed it would refuse the request, so this action opts out (the
  # showcase also allows mutations while impersonating — belt and suspenders).
  skip_before_action :current_scope_mutation_guard!, only: :destroy
  # Sandbox abuse bound. Mirrors the sessions/passwords rate_limit precedent.
  rate_limit to: 30, within: 1.minute,
    with: -> { redirect_back fallback_location: root_path, alert: "Too many switches. Try again shortly." }

  # Step into (or re-pick) a persona. Re-picking simply replaces the id.
  def create
    persona = User.find(params.expect(:id))
    session[:acting_as_id] = persona.id
    # The impersonated identity is an EXPLICIT arg: at START the ambient subject
    # still equals the actor (Current re-resolves next request).
    CurrentScope.record_impersonation_started!(persona)
    redirect_back fallback_location: root_path, notice: "Acting as #{persona.email_address}."
  end

  # Stop acting-as and return to the Visitor (or the real login).
  def destroy
    persona = User.find_by(id: session.delete(:acting_as_id))
    CurrentScope.record_impersonation_stopped!(persona) if persona
    redirect_back fallback_location: root_path, notice: "Back to browsing as Visitor."
  end
end
