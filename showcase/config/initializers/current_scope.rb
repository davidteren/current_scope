CurrentScope.configure do |config|
  # Controller method that returns the authenticated subject.
  # config.user_method = :current_user

  # Controller method returning the REAL actor while impersonating (act-as).
  # Leave unset when no one impersonates — actor then equals the subject.
  # config.actor_method = :true_user

  # Class whose instances hold roles, used by the management UI.
  # config.subject_class = "User"

  # Actions covered by the separation-of-duties veto: a record's initiator can
  # never perform these on it. Deliberately NOT editable in the UI.
  # config.sod_actions = %w[approve]

  # Controller paths (regexps) excluded from the permission grid.
  # Sessions/passwords are authentication (they skip the guard), and
  # view_components is ViewComponent's dev-only preview controller.
  config.excluded_controllers += [ %r{\Asessions\z}, %r{\Apasswords\z}, %r{\Aview_components\z} ]

  # Controller the management UI inherits from (for host auth + before_actions).
  # config.parent_controller = "::ApplicationController"
end
