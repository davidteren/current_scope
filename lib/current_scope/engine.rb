module CurrentScope
  class Engine < ::Rails::Engine
    isolate_namespace CurrentScope

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
