require "test_helper"

class PermissionCatalogTest < ActiveSupport::TestCase
  setup { @catalog = CurrentScope::PermissionCatalog.new }

  test "derives one permission per controller#action from the routes" do
    assert_includes @catalog.keys, "reports#index"
    assert_includes @catalog.keys, "reports#show"
    assert_includes @catalog.keys, "reports#destroy"
    assert_includes @catalog.keys, "reports#approve"
  end

  test "include? agrees with keys, both directions" do
    # include? reads a memoized Set rather than scanning the (display-sorted)
    # keys array — the Guard asks it on every gated request. Pin that the two
    # can't drift apart.
    @catalog.keys.each { |key| assert @catalog.include?(key), "#{key} is in keys but not include?" }

    assert_not @catalog.include?("gone#index")
    assert_not @catalog.include?("bypass_sod"), "a bare action name is not catalog-shaped"
    assert_not @catalog.include?("")
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

# The break-glass permission is not a routed action, so a route-derived catalog
# could never contain it — which made the documented "grantable, editable in the
# role grid" claim false, and left break-glass reachable only via full_access
# (defeating the point of a scoped trusted-approver role) or a console insert.
# The catalog is the single definition of what is grantable, so injecting the
# virtual key here fixes the grid render and the role save at once. (#21)
class PermissionCatalogBypassTest < ActiveSupport::TestCase
  setup do
    @original_allow = CurrentScope.config.allow_sod_bypass
    @original_actions = CurrentScope.config.sod_actions
    @original_permission = CurrentScope.config.sod_bypass_permission
  end

  teardown do
    CurrentScope.config.allow_sod_bypass = @original_allow
    CurrentScope.config.sod_actions = @original_actions
    CurrentScope.config.sod_bypass_permission = @original_permission
  end

  def catalog(allow:, actions: %w[approve], permission: "bypass_sod")
    CurrentScope.config.allow_sod_bypass = allow
    CurrentScope.config.sod_actions = actions
    CurrentScope.config.sod_bypass_permission = permission
    CurrentScope::PermissionCatalog.new
  end

  # The catalog's parse is the ONE parse (#79 review): a multi-hash value
  # would pass a last-segment check while the resolver reads the original
  # full string — an ungrantable key, a veto nobody can lift.
  test "a multi-segment bypass permission raises loudly" do
    error = assert_raises(CurrentScope::ConfigurationError) do
      catalog(allow: true, permission: "reports#bypass_sod#extra").keys
    end
    assert_match "not a bare action or a single controller#action", error.message
  end

  # routed? separates the injected break-glass key from a real routed action
  # that merely shares its name — the inertness claims (grid exempt note, task
  # strip) key on exactly this distinction. (#79 review)
  test "routed? is true for route-derived keys and false for the injected bypass key" do
    cat = catalog(allow: true, actions: %w[approve])

    assert cat.routed?("reports#approve"), "a real routed key"
    assert_includes cat.keys, "reports#bypass_sod", "precondition: bypass injected"
    assert_not cat.routed?("reports#bypass_sod"), "the injected key is not routed"
  end

  # R1: default-off is a true no-op — the catalog is what it always was.
  test "no bypass key is injected when break-glass is off (the default)" do
    keys = catalog(allow: false).keys

    assert_empty keys.grep(/#bypass_sod\z/)
  end

  test "the off-catalog is byte-for-byte the route-derived set" do
    off = catalog(allow: false).keys
    routed = Rails.application.routes.routes.filter_map { |r|
      c, a = r.defaults[:controller], r.defaults[:action]
      next unless c && a
      next if CurrentScope.config.excluded_controllers.any? { |re| c.match?(re) }

      "#{c}##{a}"
    }.uniq.sort

    assert_equal routed, off
  end

  # R2: on + a controller that routes an SoD action → the cell exists.
  test "a controller routing an SoD action gets a bypass key when break-glass is on" do
    cat = catalog(allow: true)

    assert_includes cat.keys, "reports#bypass_sod", "reports routes approve, so it can break glass"
    assert cat.include?("reports#bypass_sod")
    assert_includes cat.grouped["reports"], "bypass_sod", "and the grid must see it"
  end

  # R5: the permission only appears where it could ever mean something.
  test "nothing is injected when SoD is off, even with break-glass on" do
    keys = catalog(allow: true, actions: []).keys

    assert_empty keys.grep(/#bypass_sod\z/), "no SoD actions means no veto to break"
  end

  test "a controller that routes no SoD action gets no bypass key" do
    cat = catalog(allow: true)

    # documents routes the RESTful 7 but no `approve`.
    assert_includes cat.keys, "documents#index", "precondition: documents is in the catalog"
    assert_not cat.include?("documents#bypass_sod")
  end

  test "the injected action follows config.sod_bypass_permission" do
    cat = catalog(allow: true, permission: "override")

    assert_includes cat.keys, "reports#override"
    assert_not cat.include?("reports#bypass_sod")
  end

  test "a full-key config contributes only its action segment" do
    cat = catalog(allow: true, permission: "reports#bypass_sod")

    assert_includes cat.keys, "reports#bypass_sod"
    assert_empty cat.keys.grep(/#.*#/), "no double-# key may be produced"
  end

  test "an excluded controller contributes no bypass key" do
    original = CurrentScope.config.excluded_controllers
    # Every controller that routes approve on Report — the plain one and the
    # namespaced one — so the resource contributes nothing at all.
    CurrentScope.config.excluded_controllers = original + [ /\Areports\z/, %r{\Aadmin/reports\z} ]
    cat = catalog(allow: true)

    assert_not cat.include?("reports#approve"), "precondition: reports is excluded"
    assert_not cat.include?("admin/reports#approve"), "precondition: admin/reports is excluded"
    assert_not cat.include?("reports#bypass_sod"), "exclusion is not a back door"
  ensure
    CurrentScope.config.excluded_controllers = original
  end

  # The bypass key is named after the RESOURCE, not the controller, so it
  # survives as long as SOME non-excluded controller can perform the SoD action
  # on it. Excluding the plain ReportsController (say it's an API you gate
  # elsewhere) must not disable break-glass for reports approved through
  # Admin::ReportsController — the veto still applies there, so it must remain
  # liftable.
  test "excluding one controller does not disable break-glass for a sibling's resource" do
    original = CurrentScope.config.excluded_controllers
    CurrentScope.config.excluded_controllers = original + [ /\Areports\z/ ]
    cat = catalog(allow: true)

    assert_not cat.include?("reports#approve"), "precondition: the plain controller is excluded"
    assert_includes cat.keys, "admin/reports#approve", "but the namespaced one still gates approve"
    assert cat.include?("reports#bypass_sod"), "so that veto must still be liftable"
  ensure
    CurrentScope.config.excluded_controllers = original
  end

  test "keys stay sorted and unique" do
    keys = catalog(allow: true).keys

    assert_equal keys.uniq.sort, keys
  end

  # The key must be the one the RESOLVER will ask for. It derives the bypass key
  # from the record's route_key, never from the controller path — so for
  # Admin::ReportsController (path "admin/reports", records are Reports) the live
  # key is "reports#bypass_sod". Keying injection off the whole path would inject
  # "admin/reports#bypass_sod": a cell that grants nothing, on the shape most
  # real apps approve things in.
  test "a namespaced SoD controller injects the record's key, not its own path" do
    cat = catalog(allow: true)

    assert_includes cat.keys, "admin/reports#approve", "precondition: the namespaced route is in the catalog"
    assert_includes cat.keys, "reports#bypass_sod", "the resolver looks this up — it must exist"
    assert_not cat.include?("admin/reports#bypass_sod"), "and this one would grant nothing"
  end

  test "the injected key matches what the resolver derives for the record" do
    cat = catalog(allow: true)
    report = Report.new(title: "x")

    # The contract, asserted rather than assumed: the catalog and the resolver
    # must name the same key, or the cell is decorative.
    assert_includes cat.keys, CurrentScope.permission_key("bypass_sod", record: report)
  end

  test "two controllers on the same resource collapse to one bypass key" do
    keys = catalog(allow: true).keys

    # Both reports and admin/reports route approve.
    assert_equal 1, keys.count("reports#bypass_sod")
  end

  # A blank action segment means the initiator must hold a permission nobody can
  # hold — break-glass is inert while the host believes it is on. That is the
  # undiagnosable deny this engine promises not to ship, so it raises.
  test "a blank bypass permission raises rather than injecting a malformed key" do
    [ nil, "", "reports#" ].each do |bad|
      error = assert_raises(CurrentScope::ConfigurationError) do
        catalog(allow: true, permission: bad).keys
      end
      assert_match "sod_bypass_permission", error.message
    end
  end

  test "a malformed bypass permission never reaches the catalog as a key" do
    # "reports#" splits to ["reports"] on a plain split, which would silently
    # inject "reports#reports" — a grantable key for an action nobody routes.
    assert_raises(CurrentScope::ConfigurationError) { catalog(allow: true, permission: "reports#").keys }
  end

  test "a blank bypass permission is harmless while break-glass is off" do
    # Nothing is injected, so nothing is validated — a host that never turned
    # the feature on must not be told about its config.
    assert_nothing_raised { catalog(allow: false, permission: nil).keys }
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

  test "record wins over a different resource's controller path" do
    report = Report.new(title: "x")
    key = CurrentScope.permission_key(:show, record: report, controller_path: "projects")
    assert_equal "reports#show", key
  end

  test "a namespaced controller for the same resource wins over the record's route key" do
    report = Report.new(title: "x")
    key = CurrentScope.permission_key(:destroy, record: report, controller_path: "admin/reports")
    assert_equal "admin/reports#destroy", key
  end

  test "raises when the key cannot be derived" do
    assert_raises(ArgumentError) { CurrentScope.permission_key(:approve) }
  end
end
