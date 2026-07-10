CurrentScope.configure do |config|
  # Controller method that returns the authenticated subject.
  # config.user_method = :current_user

  # Class whose instances hold roles, used by the management UI.
  # config.subject_class = "User"

  # Actions covered by the separation-of-duties veto: a record's initiator can
  # never perform these on it. Deliberately NOT editable in the UI.
  # config.sod_actions = %w[approve]

  # Method on records that returns who initiated them (the SoD hook).
  # config.initiator_method = :current_scope_initiator

  # Controller paths (regexps) excluded from the permission grid.
  # config.excluded_controllers += [%r{\Awebhooks/}]

  # Controller the management UI inherits from (for host auth + before_actions).
  # config.parent_controller = "::ApplicationController"
end
