module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      # The public showcase is browsable by everyone: an anonymous visitor is
      # auto-signed-in as the role-less Visitor (fail-closed everywhere but the
      # lobby) rather than bounced to a login form. Real sign-in stays available.
      resume_session || start_new_session_for(User.visitor)
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      # main_app: this concern also runs inside the mounted CurrentScope
      # engine, where bare route helpers resolve against the engine's routes.
      redirect_to main_app.new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      session.delete(:acting_as_id) # sign-out ends any act-as
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
