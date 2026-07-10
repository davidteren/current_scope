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
      if respond_to?(:helper_method)
        helper_method :allowed_to?, :current_scope_user, :current_scope_actor, :impersonating?
      end
    end

    private

    def set_current_scope_user
      CurrentScope::Current.user = resolve_current_scope_subject(CurrentScope.config.user_method)

      # nil actor_method means no impersonation: leave actor unset so Current
      # falls back to the subject. Only resolve when the host opts in.
      actor_method = CurrentScope.config.actor_method
      CurrentScope::Current.actor = resolve_current_scope_subject(actor_method) if actor_method
    end

    def resolve_current_scope_subject(method)
      return send(method) if respond_to?(method, true)

      raise CurrentScope::ConfigurationError,
            "#{self.class.name} does not respond to ##{method}. Define it, or point the " \
            "matching CurrentScope.config.*_method at your method."
    end
  end
end
