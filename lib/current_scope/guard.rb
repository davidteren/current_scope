module CurrentScope
  # The enforcement point. Include after Context to gate every action behind
  # its own permission: the current controller#action IS the permission key,
  # so new controllers are gated (fail-closed) the moment they exist.
  #
  # Member actions that need record-level decisions (scoped roles, SoD)
  # declare a private current_scope_record method returning the record. Two
  # rules for the hook:
  #   - it runs for EVERY gated action, collection actions included — return
  #     nil when there is no record
  #   - it runs BEFORE the controller's own before_actions, so it must load
  #     the record itself (memoize so set_* callbacks reuse it), e.g.
  #       def current_scope_record
  #         set_report if params[:id]
  #       end
  # Skip the gate for public endpoints with skip_before_action :current_scope_check!.
  module Guard
    extend ActiveSupport::Concern

    included do
      before_action :current_scope_check!
      rescue_from CurrentScope::AccessDenied, with: :current_scope_denied
    end

    private

    def current_scope_check!
      permission = "#{controller_path}##{action_name}"
      record = respond_to?(:current_scope_record, true) ? send(:current_scope_record) : nil

      allowed = CurrentScope.resolver.allow?(
        subject: CurrentScope::Current.user, permission: permission, record: record
      )
      raise CurrentScope::AccessDenied, permission unless allowed
    end

    def current_scope_denied
      head :forbidden
    end
  end
end
