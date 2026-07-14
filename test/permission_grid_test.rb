require "test_helper"

class PermissionGridTest < ActiveSupport::TestCase
  CRUD = {
    "read" => %w[index show], "create" => %w[new create],
    "update" => %w[edit update], "destroy" => %w[destroy]
  }.freeze

  # A stand-in catalog: reports has the full RESTful set + approve; widgets is
  # read-only (index only).
  def grid(groups: CRUD)
    catalog = Struct.new(:grouped).new({
      "reports" => %w[index show new create edit update destroy approve],
      "widgets" => %w[index]
    })
    CurrentScope::PermissionGrid.new(catalog: catalog, groups: groups)
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
end
