CurrentScope.configure do |config|
  # Controller method that returns the authenticated subject.
  # config.user_method = :current_user

  # Class whose instances hold roles, used by the management UI.
  # config.subject_class = "User"

  # --- Impersonation (act-as) ---------------------------------------------
  # These three knobs layer, in this order:
  #
  #   1. actor_method                        — turns impersonation ON.
  #   2. allow_mutations_while_impersonating — the read-only gate runs FIRST.
  #   3. sod_identity                        — only observable once a mutation
  #                                            is allowed through (or on a
  #                                            GET-listed sod_action).
  #
  # Controller method returning the REAL actor while impersonating. Leave unset
  # when no one impersonates — actor then equals the subject, so attribution
  # reads current_scope_actor with no nil branch, and sod_identity below has no
  # effect. See the "Impersonation (act-as)" section of the README.
  # config.actor_method = :true_user

  # false (default): an impersonated session is read-only — every non-GET/HEAD
  # request is denied, INCLUDING the engine's management UI. Your
  # stop-impersonation, sign-out, and sign-in endpoints must opt out with
  # skip_before_action :current_scope_mutation_guard!, or impersonation (and
  # sign-in) can never clear it.
  # config.allow_mutations_while_impersonating = false

  # Which identities the separation-of-duties veto weighs. :either (default)
  # also vetoes a record the REAL actor initiated while impersonating, so
  # impersonation can never approve your own record. :subject weighs only the
  # effective subject. Identical when not impersonating.
  # config.sod_identity = :either
  # ------------------------------------------------------------------------

  # Separation of duties is OPT-IN — empty by default. List the actions a
  # record's initiator can never perform on their own record (four-eyes).
  # Deliberately NOT editable in the UI. Records reached by these actions must
  # define current_scope_initiator (return nil to exempt a record type) — the
  # resolver raises if the hook is missing. Leave commented for RBAC-only apps.
  # config.sod_actions = %w[approve]

  # Controller paths (regexps) excluded from the permission grid. Excluded
  # controllers can't be granted, so they must also skip the gate with
  # skip_before_action :current_scope_check! — Guard raises otherwise.
  # config.excluded_controllers += [%r{\Awebhooks/}]

  # Controller the management UI inherits from (for host auth + before_actions).
  # config.parent_controller = "::ApplicationController"
end
