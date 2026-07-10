module CurrentScope
  # Include in ApplicationController (before Guard). Populates the ambient
  # context from the host's authentication once per request and exposes
  # allowed_to? to actions and views. CurrentAttributes resets itself around
  # every request and job, so nothing leaks between executions.
  module Context
    extend ActiveSupport::Concern
    include Permissions

    included do
      before_action :set_current_scope_user
      helper_method :allowed_to?, :current_scope_user if respond_to?(:helper_method)
    end

    private

    def set_current_scope_user
      user_method = CurrentScope.config.user_method
      unless respond_to?(user_method, true)
        raise CurrentScope::ConfigurationError,
              "#{self.class.name} does not respond to ##{user_method}. Define it, or " \
              "point CurrentScope.config.user_method at your authentication method."
      end
      CurrentScope::Current.user = send(user_method)
    end
  end
end
