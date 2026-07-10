CurrentScope.configure do |config|
  # Controller method that returns the authenticated subject.
  # config.user_method = :current_user

  # Class whose instances hold roles, used by the management UI.
  # config.subject_class = "User"

  # Actions covered by the separation-of-duties veto: a record's initiator can
  # never perform these on it. Deliberately NOT editable in the UI. Records
  # reached by these actions must define current_scope_initiator (return nil
  # to exempt a record type) — the resolver raises if the hook is missing.
  # config.sod_actions = %w[approve]

  # Controller paths (regexps) excluded from the permission grid. Excluded
  # controllers can't be granted, so they must also skip the gate with
  # skip_before_action :current_scope_check! — Guard raises otherwise.
  # config.excluded_controllers += [%r{\Awebhooks/}]

  # Controller the management UI inherits from (for host auth + before_actions).
  # config.parent_controller = "::ApplicationController"
end
