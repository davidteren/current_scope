module CurrentScope
  # Presents the route-derived permission catalog as an ALIGNED matrix for the
  # role editor: fixed columns, one row per controller, blank cells where a
  # controller doesn't route a column's actions (never a shifted cell).
  #
  # By default the columns are CRUD groups (config.permission_grid_groups):
  # ticking one grants every routed action in the group, so the RESTful form
  # actions fold into their mutation (new→create, edit→update) and index+show
  # read as one. Actions outside any group (e.g. "approve") get their own
  # column. With groups set to nil/{} every raw action becomes its own column —
  # still aligned.
  class PermissionGrid
    Column = Struct.new(:label, :actions, :group, keyword_init: true)
    Cell   = Struct.new(:blank, :group, :name, :value, :checked, :partial, keyword_init: true)

    def initialize(catalog: CurrentScope.catalog, groups: CurrentScope.config.permission_grid_groups)
      @grouped = catalog.grouped # { "controller" => ["action", ...] }
      @groups  = groups || {}
    end

    def controllers
      @grouped.keys.sort
    end

    # Ordered columns: config groups that apply to at least one controller (in
    # config order), then leftover actions not covered by any group (sorted).
    def columns
      grouped = @groups.filter_map do |label, actions|
        Column.new(label: label, actions: actions, group: true) if any_controller_has?(actions)
      end
      grouped + leftover_actions.map { |action| Column.new(label: action, actions: [ action ], group: false) }
    end

    # One cell for (controller, column) against a role's granted key set.
    # Blank when the controller routes none of the column's actions. Otherwise a
    # checkbox: `checked` when ANY routed action is granted (additive-safe — the
    # column never silently revokes on save), `partial` when some-but-not-all.
    def cell(controller, column, granted)
      routed = column.actions & actions_for(controller)
      return Cell.new(blank: true) if routed.empty?

      keys = routed.map { |action| "#{controller}##{action}" }
      present = keys.count { |key| granted.include?(key) }
      Cell.new(
        blank: false,
        group: column.group,
        name:  column.group ? "role[permission_groups][]" : "role[permission_keys][]",
        value: column.group ? "#{controller}:#{column.label}" : keys.first,
        checked: present.positive?,
        partial: present.positive? && present < keys.size
      )
    end

    # Expand submitted "controller:group" tokens into routed permission keys.
    # Unknown groups/controllers and unrouted actions drop out.
    def expand(tokens)
      Array(tokens).flat_map do |token|
        controller, label = token.to_s.split(":", 2)
        actions = @groups[label]
        next [] if actions.nil?

        (actions & actions_for(controller)).map { |action| "#{controller}##{action}" }
      end
    end

    def actions_for(controller)
      @grouped[controller] || []
    end

    private

    def any_controller_has?(actions)
      @grouped.values.any? { |routed| routed.intersect?(actions) }
    end

    def leftover_actions
      grouped = @groups.values.flatten.uniq
      (@grouped.values.flatten.uniq - grouped).sort
    end
  end
end
