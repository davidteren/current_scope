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
      Rails.application.routes.routes.filter_map { |route|
        controller = route.defaults[:controller]
        action = route.defaults[:action]
        next unless controller && action
        next if CurrentScope.config.excluded_controllers.any? { |re| controller.match?(re) }

        "#{controller}##{action}"
      }.uniq.sort
    end
  end
end
