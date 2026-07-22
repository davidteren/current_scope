module CurrentScope
  class Engine < ::Rails::Engine
    isolate_namespace CurrentScope

    # An AccessDenied that escapes any Guard rescue (PORO, Context-only
    # controller, re-raise) must 403, not 500. Never turns a deny into an
    # allow — the exception already blocked the action (#39).
    #
    # ||= so a host that already set this mapping (e.g. :not_found to hide
    # existence) in config/application.rb is not clobbered. before:
    # action_dispatch.configure so ExceptionWrapper.rescue_responses picks the
    # entry up when it merge!s the config hash.
    initializer "current_scope.rescue_responses", before: "action_dispatch.configure" do |app|
      app.config.action_dispatch.rescue_responses["CurrentScope::AccessDenied"] ||= :forbidden
    end

    # Belt for Rails upgrades: if action_dispatch.configure is renamed/reordered
    # and the config merge is missed, still pin the class map. Use key? — the
    # ExceptionWrapper hash defaults missing keys to :internal_server_error
    # (truthy), so ||= would never write.
    initializer "current_scope.rescue_responses_apply", after: "action_dispatch.configure" do
      map = ActionDispatch::ExceptionWrapper.rescue_responses
      map["CurrentScope::AccessDenied"] = :forbidden unless map.key?("CurrentScope::AccessDenied")
    end

    # Cross-field config invariants (e.g. bypass permission ∉ sod_actions) must
    # run AFTER the host initializer has assigned every field — a writer on
    # either attr alone is order-dependent. once, not on to_prepare (config
    # does not change on code reload). #40.
    config.after_initialize do
      CurrentScope.config.validate!
    end

    # Routes (and therefore the derived permission catalog) can change on
    # every code reload in development, and reloaded host models must re-register
    # as scopeable rather than pile up stale/duplicate entries. Both reset here,
    # ahead of eager-load, so the registry rebuilds cleanly.
    config.to_prepare do
      CurrentScope.reset_catalog!
      CurrentScope.reset_scopeable_registry!
      # The cross-controller nudge warns once per site; a reload can change what's
      # routed, so a stale latch would hide a divergence the edit just created.
      CurrentScope.reset_cross_controller_warnings!
      # Same reason for the tripwire's :warn latch: a reload can change whether a
      # controller#action is gated, and a stale latch would hand a dev running
      # :warn a false all-clear right after the edit.
      CurrentScope::GatingTripwire.reset_warnings!
    end
  end
end
