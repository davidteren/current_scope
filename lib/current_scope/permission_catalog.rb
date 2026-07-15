module CurrentScope
  # Derives the permission set from the host's routes: one permission per
  # controller#action pair. There is no table to maintain — add a controller
  # and its actions appear in the grid on next boot/reload.
  class PermissionCatalog
    def keys
      @keys ||= derive
    end

    # { "reports" => ["approve", "create", ...], ... } for the role-editor grid.
    def grouped
      keys.group_by { |key| key.split("#").first }
          .transform_values { |ks| ks.map { |k| k.split("#").last } }
    end

    # Hot: the Guard asks this on EVERY gated request, and a role save asks it
    # once per staged key. Set lookup, not Array#include? — the array is sorted
    # for display, and scanning it linearly made every request pay for the size
    # of the host's route table. Memoized alongside `keys` and dropped with it
    # on reset!.
    def include?(key)
      key_set.include?(key)
    end

    private

    def key_set
      @key_set ||= keys.to_set
    end

    def derive
      routed = Rails.application.routes.routes.filter_map { |route|
        controller = route.defaults[:controller]
        action = route.defaults[:action]
        next unless controller && action
        next if CurrentScope.config.excluded_controllers.any? { |re| controller.match?(re) }

        "#{controller}##{action}"
      }.uniq

      (routed + bypass_keys(routed)).uniq.sort
    end

    # Break-glass is the one permission that isn't an action you can route: it
    # gates the SoD veto rather than a request. So a purely route-derived catalog
    # can never contain it — which left the shipped "grantable, editable in the
    # role grid" claim false, and break-glass reachable only through full_access
    # (defeating the point of a *scoped* trusted-approver role) or a console
    # insert. The catalog is the single definition of what is grantable — the
    # grid reads `grouped`, the role setter and the Guard read `include?` — so
    # injecting the virtual key here makes the cell render AND the save stick,
    # with no special case in either. (#21)
    #
    # Emitted only where it could mean something: break-glass on, and a
    # controller that actually routes an SoD action. Off by default, so the
    # catalog is byte-for-byte the routed set unless a host opts in.
    #
    # Route- and config-derived only — deliberately no model introspection. The
    # precise set would be "controllers whose SoD-gated model defines an
    # initiator", but discovering that means loading application models, which
    # is expensive, boot-order fragile, and against the catalog's whole design.
    # Over-inclusion is fail-safe (a cell the resolver never consults grants
    # nothing). Under-inclusion is NOT, and is the honest limit here: the
    # resolver keys the bypass off the RECORD's route_key, so a controller whose
    # name differs from the record's (an `approvals` controller acting on
    # `Invoice`) gets a dead `approvals#bypass_sod` cell while the live
    # `invoices#bypass_sod` is never injected. Conventional resource controllers
    # — where controller name == route_key — are unaffected. Tracked at OQ-2.
    def bypass_keys(routed)
      return [] unless CurrentScope.config.allow_sod_bypass

      sod_actions = CurrentScope.config.sod_actions
      return [] if sod_actions.empty?

      # Tolerate either a bare action ("bypass_sod") or a full key.
      bypass_action = CurrentScope.config.sod_bypass_permission.to_s.split("#").last

      routed.group_by { |key| key.split("#").first }
            .filter_map { |controller, keys|
              actions = keys.map { |k| k.split("#").last }
              "#{controller}##{bypass_action}" if actions.intersect?(sod_actions)
            }
    end
  end
end
