require "test_helper"

class PermissionCatalogTest < ActiveSupport::TestCase
  setup { @catalog = CurrentScope::PermissionCatalog.new }

  test "derives one permission per controller#action from the routes" do
    assert_includes @catalog.keys, "reports#index"
    assert_includes @catalog.keys, "reports#show"
    assert_includes @catalog.keys, "reports#destroy"
    assert_includes @catalog.keys, "reports#approve"
  end

  test "excludes infrastructure and engine controllers" do
    assert_not @catalog.keys.any? { |k| k.start_with?("rails/") }
    assert_not @catalog.keys.any? { |k| k.start_with?("active_storage/") }
    assert_not @catalog.keys.any? { |k| k.start_with?("current_scope/") }
  end

  test "groups actions by controller for the grid" do
    assert_equal %w[approve destroy index show], @catalog.grouped["reports"].sort
  end
end

class PermissionKeyTest < ActiveSupport::TestCase
  test "passes through a full key" do
    assert_equal "admin/reports#approve", CurrentScope.permission_key("admin/reports#approve")
  end

  test "derives the key from a record's route key" do
    report = Report.new(title: "x")
    assert_equal "reports#approve", CurrentScope.permission_key(:approve, record: report)
  end

  test "derives the key from a model class" do
    assert_equal "reports#create", CurrentScope.permission_key(:create, record: Report)
  end

  test "falls back to the controller path" do
    assert_equal "reports#index", CurrentScope.permission_key(:index, controller_path: "reports")
  end

  test "record wins over controller path" do
    report = Report.new(title: "x")
    key = CurrentScope.permission_key(:show, record: report, controller_path: "projects")
    assert_equal "reports#show", key
  end

  test "raises when the key cannot be derived" do
    assert_raises(ArgumentError) { CurrentScope.permission_key(:approve) }
  end
end
