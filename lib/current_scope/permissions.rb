module CurrentScope
  # The portable authorization mixin. Works anywhere — controllers, views,
  # components, POROs — because the subject comes from the ambient
  # CurrentScope::Current context rather than being threaded through calls.
  # Everything delegates to the one resolver, so a view can never disagree
  # with the controller gate.
  #
  #   allowed_to?(:approve, report)          # key derived from the record
  #   allowed_to?(:create, Report)           # class works for collection actions
  #   allowed_to?("admin/reports#approve")   # explicit full key
  #   allowed_to?(:index, controller: "reports")
  module Permissions
    def allowed_to?(action, record = nil, controller: nil)
      controller ||= controller_path if respond_to?(:controller_path)
      CurrentScope.allowed?(action, subject: current_scope_user, record: record,
        controller_path: controller, actor: current_scope_actor)
    end

    # The list-side companion to allowed_to?: "which records of `model` may the
    # effective subject act on?". Same grants, keys, and fail-closed rules as
    # the gate, so a list can't drift from the per-record decision. Returns a
    # chainable relation (.where/.order/.page on it). `permission` defaults to
    # the model's index context and accepts a bare action or a full key.
    #
    #   scope_for(Project)                 # projects#index — what a list shows
    #   scope_for(Report, permission: :approve)
    #   scope_for(Report, permission: "admin/reports#approve")
    def scope_for(model, permission: nil)
      CurrentScope.scope_for(
        subject: current_scope_user,
        model: model,
        permission: CurrentScope.permission_key(permission || :index, record: model)
      )
    end

    def current_scope_user
      CurrentScope::Current.user
    end

    # The REAL actor behind the request (never nil when a subject is set — it
    # falls back to the subject). Read this for attribution, not Current.
    def current_scope_actor
      CurrentScope::Current.actor
    end

    # True only while a distinct real actor stands behind the effective
    # subject (act-as). Views use it as the read-only-state signal.
    def impersonating?
      CurrentScope::Current.user.present? &&
        CurrentScope::Current.actor != CurrentScope::Current.user
    end
  end
end
