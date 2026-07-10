module CurrentScope
  # The portable authorization mixin. Works anywhere — controllers, views,
  # components, POROs — because the subject comes from the ambient
  # CurrentScope::Current context rather than being threaded through calls.
  # Everything delegates to the one resolver, so a view can never disagree
  # with the controller gate.
  #
  #   allowed_to?(:approve, report)          # key derived from the record
  #   allowed_to?("admin/reports#approve")   # explicit full key
  #   allowed_to?(:index, controller: "reports")
  module Permissions
    def allowed_to?(action, record = nil, controller: nil)
      controller ||= controller_path if respond_to?(:controller_path)
      CurrentScope.allowed?(action, subject: current_scope_user, record: record, controller_path: controller)
    end

    def current_scope_user
      CurrentScope::Current.user
    end
  end
end
