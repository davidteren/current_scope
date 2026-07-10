module CurrentScope
  # The enforcement point. Include after Context to gate every action behind
  # its own permission: the current controller#action IS the permission key,
  # so new controllers are gated (fail-closed) the moment they exist.
  #
  # Member actions that need record-level decisions (scoped roles, SoD)
  # declare a private current_scope_record method returning the record. Three
  # rules for the hook:
  #   - it runs for EVERY gated action, collection actions included — return
  #     nil when there is no record
  #   - it runs BEFORE the controller's own before_actions, so it must load
  #     the record itself (memoize so set_* callbacks reuse it)
  #   - key off request.path_parameters, NEVER params: a query-string ?id=
  #     must not let a scoped role on one record unlock a collection action
  #
  #       def current_scope_record
  #         set_report if request.path_parameters[:id]
  #       end
  #
  # Skip the gate for public endpoints with skip_before_action :current_scope_check!.
  # MutationGuard (included here) adds the read-only-while-impersonating gate as
  # its OWN before_action, so it runs first and survives that skip.
  module Guard
    extend ActiveSupport::Concern
    include MutationGuard

    included do
      before_action :current_scope_check!
    end

    private

    def current_scope_check!
      permission = "#{controller_path}##{action_name}"

      # An excluded controller can never be granted in the grid, so gating it
      # would lock it to full_access forever — a misconfiguration, not a deny.
      unless CurrentScope.catalog.include?(permission)
        raise CurrentScope::ConfigurationError,
              "\"#{permission}\" is not in the permission catalog (excluded_controllers " \
              "or not routed). Either stop excluding it, or skip the gate here with " \
              "skip_before_action :current_scope_check!."
      end

      record = respond_to?(:current_scope_record, true) ? send(:current_scope_record) : nil

      # The real actor (Current.actor) enters here explicitly — the resolver
      # never reads Current itself (PDP purity). It only matters under SoD
      # :either while impersonating; otherwise actor == subject.
      allowed, reason = CurrentScope.resolver.decide(
        subject: CurrentScope::Current.user, permission: permission,
        record: record, actor: CurrentScope::Current.actor
      )
      raise CurrentScope::AccessDenied.new(permission, reason: reason) unless allowed
    end
  end
end
