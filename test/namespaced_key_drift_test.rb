require "test_helper"

# A8: pin the documented namespaced/custom-controller drift. permission_key
# prefers the record's route-key form UNLESS the current controller_path's last
# segment equals that route key. The Guard always enforces controller_path#action,
# so a custom-named controller (path segment != route key) makes the short-form
# helper resolve a DIFFERENT key than the gate — a shown-but-403 display bug (not
# a bypass; the gate stays authoritative). The full-key form removes the drift.
class NamespacedKeyDriftTest < ActiveSupport::TestCase
  setup do
    @report = Report.create!(title: "Q3", requested_by: User.create!(name: "Bob"))
  end

  test "agreement: controller path segment == route key" do
    # Admin::ReportsController — path last segment "reports" == route_key "reports".
    assert_equal "admin/reports#show",
                 CurrentScope.permission_key(:show, record: @report, controller_path: "admin/reports")
  end

  test "drift: custom-named controller resolves the route-key form, not its own path" do
    # DashboardController rendering a Report — path "dashboard" != route_key "reports".
    # The helper derives reports#show, but the Guard for DashboardController enforces
    # dashboard#show. They differ — the documented foot-gun.
    assert_equal "reports#show",
                 CurrentScope.permission_key(:show, record: @report, controller_path: "dashboard")
  end

  test "full-key form removes the ambiguity" do
    assert_equal "dashboard#show", CurrentScope.permission_key("dashboard#show", record: @report)
  end
end
