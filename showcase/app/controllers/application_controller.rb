class ApplicationController < ActionController::Base
  include Authentication
  include CurrentScope::Context
  include CurrentScope::Guard

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :act_as_personas

  private

  def current_user
    Current.user
  end

  # The REAL actor: always the signed-in account, never the impersonated one.
  # Wired as CurrentScope's actor_method.
  def true_user = current_user

  # The EFFECTIVE subject CurrentScope authorizes as: the impersonated persona
  # when acting-as, otherwise the real actor. Re-resolved from the session every
  # request (never cached across requests in Current). Wired as user_method.
  def current_scope_user
    return @current_scope_user if defined?(@current_scope_user)

    @current_scope_user = acting_as || true_user
  end

  # The impersonated persona, or nil. A stale key (persona deleted by a sandbox
  # reset) is cleared LOUDLY — flashed and dropped — never silently ridden.
  def acting_as
    id = session[:acting_as_id]
    return unless id

    User.find_by(id: id) || clear_stale_acting_as
  end

  def clear_stale_acting_as
    session.delete(:acting_as_id)
    flash.now[:alert] = "The sandbox was reset — you're back to Visitor."
    nil
  end

  # Seeded personas a Visitor can step into (everyone but the Visitor itself).
  def act_as_personas
    User.where.not(id: User.visitor.id).order(:email_address)
  end
end
