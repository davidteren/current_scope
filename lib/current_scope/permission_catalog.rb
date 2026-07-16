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

    # The ONE parse of config.sod_bypass_permission's action segment — the grid
    # view and the ungated task read it here rather than re-splitting the
    # string themselves (a looser split("#").last silently turns a malformed
    # "reports#" into "reports" and mislabels the break-glass cell; #79 review).
    #
    # `split("#", -1)` keeps the trailing empty field, so a malformed "reports#"
    # yields "" and is caught here rather than silently becoming "reports" and
    # injecting "reports#reports". Blank raises instead of skipping: the host
    # turned break-glass ON, so a permission nobody can hold means the veto can
    # never be lifted and the feature is inert — an undiagnosable deny, which is
    # exactly what this engine promises not to do. (A boot-time check for this
    # config belongs with #40.)
    def bypass_action
      action = CurrentScope.config.sod_bypass_permission.to_s.split("#", -1).last
      return action if action.present?

      raise ConfigurationError,
            "config.allow_sod_bypass is on, but config.sod_bypass_permission " \
            "(#{CurrentScope.config.sod_bypass_permission.inspect}) has no action segment. " \
            "Name the permission the record's initiator must hold to break glass " \
            "(the default is \"bypass_sod\"), or set config.allow_sod_bypass = false."
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
    #
    # The key is built from the controller's LAST path segment, because that is
    # what the resolver will ask for: it derives the bypass key from the
    # RECORD's route_key (permission_key → record.model_name.route_key), never
    # from the controller path. Under Rails' resource conventions those agree —
    # Admin::ReportsController's last segment "reports" IS Report's route_key —
    # so keying off the whole path would inject "admin/reports#bypass_sod" while
    # the resolver looks up "reports#bypass_sod", leaving break-glass ungrantable
    # for every namespaced SoD controller and handing the admin a cell that
    # silently does nothing. Namespaced admin controllers are common enough that
    # this is the difference between the fix working and not.
    #
    # A namespace-only resource therefore gets its bypass cell on a "reports"
    # row that no controller routes — the grid renders it aligned, blank
    # everywhere else. Slightly odd to look at, and correct: it is the key the
    # resolver actually reads.
    #
    # The irreducible limit: a controller named differently from the records it
    # acts on (an `approvals` controller approving `Invoice`s) still injects
    # `approvals#bypass_sod` while the live key is `invoices#bypass_sod`.
    # Closing that needs to know the SoD-gated model, i.e. introspection.
    # Tracked at OQ-2.
    def bypass_keys(routed)
      return [] unless CurrentScope.config.allow_sod_bypass

      sod_actions = CurrentScope.config.sod_actions
      return [] if sod_actions.empty?

      routed.group_by { |key| key.split("#").first }
            .filter_map { |controller, keys|
              actions = keys.map { |k| k.split("#").last }
              "#{controller.split('/').last}##{bypass_action}" if actions.intersect?(sod_actions)
            }
    end

    # The action segment of config.sod_bypass_permission — tolerating either a
    # bare action ("bypass_sod") or a full key ("reports#bypass_sod").
    #
  end
end
