require "test_helper"

class PermissionGridTest < ActiveSupport::TestCase
  CRUD = {
    "read" => %w[index show], "create" => %w[new create],
    "update" => %w[edit update], "destroy" => %w[destroy]
  }.freeze

  # A stand-in catalog: reports has the full RESTful set + approve; widgets is
  # read-only (index only).
  def grid(groups: CRUD, **kwargs)
    catalog = Struct.new(:grouped).new({
      "reports" => %w[index show new create edit update destroy approve],
      "widgets" => %w[index]
    })
    CurrentScope::PermissionGrid.new(catalog: catalog, groups: groups, **kwargs)
  end

  # Stand-in reflections, mirroring the catalog stand-in above. Same duck as
  # GatingReflection: one #ungated?(controller) predicate.
  class MarkingReflection
    def initialize(*marked)
      @marked = marked
    end

    def ungated?(controller)
      @marked.include?(controller)
    end
  end

  class SpyReflection
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def ungated?(_controller)
      @calls += 1
      true
    end
  end

  test "controllers are sorted" do
    assert_equal %w[reports widgets], grid.controllers
  end

  test "columns are CRUD groups in config order, then leftover actions sorted" do
    labels = grid.columns.map(&:label)
    assert_equal %w[read create update destroy approve], labels
  end

  test "raw mode (no groups) makes every action its own aligned column" do
    labels = grid(groups: nil).columns.map(&:label)
    assert_equal %w[approve create destroy edit index new show update], labels
  end

  test "a controller missing a column's actions gets a blank cell" do
    columns = grid.columns
    update_col = columns.find { |c| c.label == "update" }
    approve_col = columns.find { |c| c.label == "approve" }

    assert grid.cell("widgets", update_col, Set.new).blank, "widgets has no edit/update route"
    assert grid.cell("widgets", approve_col, Set.new).blank, "widgets has no approve route"
    assert_not grid.cell("reports", update_col, Set.new).blank
  end

  test "a group cell submits a controller:group token on the groups channel" do
    read_col = grid.columns.find { |c| c.label == "read" }
    cell = grid.cell("reports", read_col, Set.new)
    assert_equal "role[permission_groups][]", cell.name
    assert_equal "reports:read", cell.value
  end

  test "a leftover action cell submits a raw permission key" do
    approve_col = grid.columns.find { |c| c.label == "approve" }
    cell = grid.cell("reports", approve_col, Set.new)
    assert_equal "role[permission_keys][]", cell.name
    assert_equal "reports#approve", cell.value
  end

  test "a partial group is unchecked (not silently promoted) and preserves its keys" do
    read_col = grid.columns.find { |c| c.label == "read" }

    # Escalation guard: a partial group must NOT render checked — a checked group
    # token expands to the whole group on save, so a re-save would broaden it.
    partial = grid.cell("reports", read_col, Set["reports#index"])
    assert_not partial.checked
    assert partial.partial
    assert_equal %w[reports#index], partial.granted_keys

    full = grid.cell("reports", read_col, Set["reports#index", "reports#show"])
    assert full.checked
    assert_not full.partial
    assert_empty full.granted_keys

    none = grid.cell("reports", read_col, Set.new)
    assert_not none.checked
    assert_not none.partial
    assert_empty none.granted_keys
  end

  test "a leftover (single-action) cell stays checked when granted — never partial" do
    approve_col = grid.columns.find { |c| c.label == "approve" }
    cell = grid.cell("reports", approve_col, Set["reports#approve"])
    assert cell.checked
    assert_not cell.partial
    assert_empty cell.granted_keys
  end

  test "expand turns group tokens into the routed permission keys" do
    assert_equal %w[reports#index reports#show], grid.expand([ "reports:read" ]).sort
    assert_equal %w[reports#create reports#new], grid.expand([ "reports:create" ]).sort
    # widgets routes only index → create group expands to nothing there
    assert_empty grid.expand([ "widgets:create" ])
    # unknown group / junk token
    assert_empty grid.expand([ "reports:nope", "", "garbage" ])
  end

  # --- Break-glass renders as an ordinary column (#21) ---
  #
  # The whole point of injecting the virtual key at the CATALOG rather than
  # special-casing the grid: bypass_sod is outside permission_grid_groups, so
  # the existing leftover-column machinery already renders it correctly. These
  # pin that no bespoke UI is needed — if they ever fail, someone has started
  # building one.

  # The catalog after injection: reports (which routes approve) has bypass_sod;
  # widgets does not.
  def bypass_grid
    catalog = Struct.new(:grouped).new({
      "reports" => %w[index show new create edit update destroy approve bypass_sod],
      "widgets" => %w[index]
    })
    CurrentScope::PermissionGrid.new(catalog: catalog, groups: CRUD)
  end

  test "the bypass permission gets its own leftover column, like approve" do
    column = bypass_grid.columns.find { |c| c.label == "bypass_sod" }

    assert column, "an injected bypass key must surface as a column"
    assert_not column.group, "it is a single action, not a CRUD group"
    assert_equal %w[bypass_sod], column.actions
  end

  test "the bypass cell is a real checkbox on a controller that can break glass" do
    column = bypass_grid.columns.find { |c| c.label == "bypass_sod" }
    cell = bypass_grid.cell("reports", column, Set.new)

    assert_not cell.blank
    assert_equal "reports#bypass_sod", cell.value
    assert_equal "role[permission_keys][]", cell.name, "the raw key channel, not a group token"
    assert_not cell.checked
  end

  test "the bypass cell reads as granted when the role holds the key" do
    column = bypass_grid.columns.find { |c| c.label == "bypass_sod" }
    cell = bypass_grid.cell("reports", column, Set["reports#bypass_sod"])

    assert cell.checked
  end

  test "a controller that cannot break glass renders a blank bypass cell" do
    column = bypass_grid.columns.find { |c| c.label == "bypass_sod" }
    cell = bypass_grid.cell("widgets", column, Set.new)

    assert cell.blank, "alignment holds — no shifted cells"
  end

  # --- Gating reflection: the row question, provably advisory-only ---
  #
  # The grid answers "is this row's controller provably ungated?" by delegating
  # to an injected GatingReflection. These pin that the reflection is read AND
  # ignored everywhere else: it cannot change what a cell renders or what a
  # group token expands to, and the grid never calls it during construction or
  # expand (KTD-8: role_params builds a bare grid on every role save).

  test "ungated? delegates to the injected reflection per controller" do
    g = grid(gating: MarkingReflection.new("widgets"))

    assert g.ungated?("widgets")
    assert_not g.ungated?("reports")
  end

  test "cell output is byte-identical whether or not the reflection marks the controller" do
    marked   = grid(gating: MarkingReflection.new("reports", "widgets"))
    unmarked = grid(gating: MarkingReflection.new)
    read_col    = unmarked.columns.find { |c| c.label == "read" }
    approve_col = unmarked.columns.find { |c| c.label == "approve" }

    [
      [ "reports", read_col, Set["reports#index", "reports#show"] ], # checked group
      [ "reports", read_col, Set.new ],                              # unchecked
      [ "reports", read_col, Set["reports#index"] ],                 # partial group
      [ "widgets", approve_col, Set.new ]                            # blank
    ].each do |controller, column, granted|
      assert_equal unmarked.cell(controller, column, granted).to_h,
                   marked.cell(controller, column, granted).to_h,
                   "#{controller}/#{column.label} cell drifted under a marking reflection"
    end
  end

  test "expand output is identical under a marking reflection" do
    marked = grid(gating: MarkingReflection.new("reports"))

    assert_equal grid.expand([ "reports:read" ]), marked.expand([ "reports:read" ])
    assert_equal %w[reports#index reports#show], marked.expand([ "reports:read" ]).sort
  end

  test "construction and expand never touch the reflection" do
    spy = SpyReflection.new
    g = grid(gating: spy)

    assert_equal 0, spy.calls, "initialize must not reflect (KTD-8: every role save constructs a grid)"

    g.expand([ "reports:read", "widgets:create" ])
    assert_equal 0, spy.calls, "expand (the role_params path) must not reflect"
  end

  test "bare PermissionGrid.new (the view and role_params call shape) defaults to a real reflection" do
    g = CurrentScope::PermissionGrid.new

    assert_instance_of CurrentScope::GatingReflection, g.instance_variable_get(:@gating)
  end
end
