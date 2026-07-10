module CurrentScope
  # Inherits from the host's controller (config.parent_controller) so the
  # host's authentication — and its Context before_action — run first.
  # The management UI is the place permissions are granted, so it cannot be
  # gated by grantable permissions: only full_access subjects get in.
  class ApplicationController < CurrentScope.config.parent_controller.constantize
    layout "current_scope/application"

    before_action :require_full_access!

    private

    def require_full_access!
      head :forbidden unless CurrentScope.resolver.full_access?(CurrentScope::Current.user)
    end
  end
end
