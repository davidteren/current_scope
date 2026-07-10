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

    def include?(key)
      keys.include?(key)
    end

    private

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
