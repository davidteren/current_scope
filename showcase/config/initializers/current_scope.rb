CurrentScope.configure do |config|
  # Controller method that returns the authenticated subject.
  # config.user_method = :current_user

  # Class whose instances hold roles, used by the management UI.
  # config.subject_class = "User"

  # --- Impersonation (act-as) ---------------------------------------------
  # These three knobs layer in order: actor_method turns impersonation on;
  # allow_mutations_while_impersonating (the read-only gate) runs FIRST, so
  # sod_identity is only observable once a mutation is allowed through (or on a
  # GET-listed sod_action).
  #
  # Controller method returning the REAL actor while impersonating. Leave unset
  # when no one impersonates — actor then equals the subject, and sod_identity
  # has no effect.
  # config.actor_method = :true_user

  # false (default): an impersonated session is read-only — every non-GET/HEAD
  # request is denied, INCLUDING the management UI. Stop-impersonation,
  # sign-out, and sign-in endpoints must skip_before_action
  # :current_scope_mutation_guard!, or impersonation can never end.
  # config.allow_mutations_while_impersonating = false

  # :either (default) also vetoes a record the REAL actor initiated while
  # impersonating — impersonation can never approve your own record. :subject
  # weighs only the effective subject.
  # config.sod_identity = :either
  # ------------------------------------------------------------------------

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
