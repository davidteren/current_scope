require "test_helper"

# The role editor's aligned CRUD grid: fixed columns, grouped checkboxes that
# grant the underlying routed actions.
class RoleGridTest < ActionDispatch::IntegrationTest
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @role = CurrentScope::Role.create!(name: "Editor")
  end

  def as(user) = { "X-User-Id" => user.id.to_s }

  test "the grid renders fixed CRUD column headers" do
    get current_scope.edit_role_url(@role), headers: as(@owner)
    assert_response :success
    assert_select "thead th", text: "read"
    assert_select "thead th", text: "create"
    assert_select "thead th", text: "update"
    assert_select "thead th", text: "destroy"
    # Columns are absolute: every body row renders one sticky header + one cell
    # per column (blanks included), so the first row's child count is aligned.
    columns = CurrentScope::PermissionGrid.new.columns.size
    assert_select "tbody tr:first-child > *", count: columns + 1
  end

  test "ticking a CRUD group grants every routed action in it" do
    # reports routes index + show; the "read" group should grant both.
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", full_access: "0", permission_groups: [ "reports:read" ] } }
    assert_redirected_to current_scope.roles_path

    keys = @role.reload.permission_keys
    assert_includes keys, "reports#index"
    assert_includes keys, "reports#show"
  end

  test "a role carries an optional description" do
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", description: "May edit and approve reports", full_access: "0" } }
    assert_equal "May edit and approve reports", @role.reload.description

    get current_scope.roles_url, headers: as(@owner)
    assert_select ".cs-subtle", text: "May edit and approve reports"
  end

  test "a partially granted group renders unchecked and preserves its exact keys" do
    @role.update!(permission_keys: [ "reports#index" ]) # read = index only (show not granted)
    get current_scope.edit_role_url(@role), headers: as(@owner)
    assert_response :success
    # The read group cell must NOT be checked: a checked group token expands to
    # the whole group on save, which would silently broaden the grant.
    assert_select "input#perm_reports_read[type=checkbox]" do |els|
      assert_nil els.first["checked"], "a partial group must not render checked"
    end
    # Its existing key rides along as a hidden input so a no-op save keeps it.
    assert_select "input[type=hidden][name='role[permission_keys][]'][value='reports#index'][data-cs-preserve]"
  end

  test "re-saving a partially granted role does not broaden it to the full group" do
    @role.update!(permission_keys: [ "reports#index" ])
    # What the no-JS form submits for an untouched partial: the preserved key,
    # and no group token (the checkbox is unchecked).
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Renamed", full_access: "0", permission_keys: [ "reports#index" ] } }
    keys = @role.reload.permission_keys
    assert_includes keys, "reports#index"
    assert_not_includes keys, "reports#show", "re-saving must not silently grant the rest of the read group"
  end

  test "raw permission_keys still work alongside the group channel" do
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", full_access: "0",
                            permission_keys: [ "reports#approve" ],
                            permission_groups: [ "reports:read" ] } }
    keys = @role.reload.permission_keys
    assert_includes keys, "reports#approve"
    assert_includes keys, "reports#index"
  end

  # --- The strict-key validation must not disturb the editor (#20) ---
  #
  # permission_keys= now rejects a key outside the catalog instead of dropping
  # it. The grid is its highest-traffic caller, so these are the guardrail that
  # the strict default didn't land on the operator: the grid builds cells from
  # routed actions only, so everything it submits is already in the catalog.

  test "a stale key from a removed controller is cleaned up transparently on save" do
    # A role holding a key whose controller no longer routes — what's left after
    # a controller is deleted. Inserted directly, since the strict setter is now
    # exactly what refuses to create this state.
    @role.role_permissions.insert_all([ { permission_key: "reports#index" },
                                        { permission_key: "gone#index" } ])
    assert_includes @role.reload.permission_keys, "gone#index"

    # The grid never renders a row for an unrouted controller, so it never
    # round-trips the stale key: the submitted set is all-catalog and valid.
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", full_access: "0",
                            permission_keys: [ "", "reports#index" ] } }

    assert_redirected_to current_scope.roles_url, "the operator must not see an error for someone else's mess"
    assert_equal [ "reports#index" ], @role.reload.permission_keys, "the stale key is gone"
  end

  test "a stale key does not block an unrelated edit to the role" do
    @role.role_permissions.insert_all([ { permission_key: "gone#index" } ])

    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Renamed", full_access: "0", permission_keys: [ "" ] } }

    assert_redirected_to current_scope.roles_url
    assert_equal "Renamed", @role.reload.name
  end

  test "the edit view never renders a hidden input for a stale key" do
    @role.role_permissions.insert_all([ { permission_key: "reports#index" },
                                        { permission_key: "gone#index" } ])

    get current_scope.edit_role_url(@role), headers: as(@owner)
    assert_response :success
    # The claim the strict default rests on: if the grid could round-trip a
    # stale key, every save of this role would 422 on a mess the operator
    # didn't make and can't see.
    assert_select "input[value=?]", "gone#index", count: 0
  end

  # --- Marking provably-ungated controllers (#62 — R5/R9, KTD-8/KTD-9) ---
  #
  # PermissionGrid#ungated? is advisory: the badge names the fact ("gate not
  # run"), the consequence (ticking routed actions grants nothing) and the
  # remediation (GatingTripwire's vocabulary) — and disables NOTHING, because
  # marking is not disabling. Break-glass is the one live cell on a marked row
  # (the SoD veto is decided by GATED controllers acting on the record type),
  # so it is exempt from the badge's claim and says so per-cell.

  test "provably-ungated rows carry the gate-not-run badge; gated and unprovable rows do not" do
    get current_scope.edit_role_url(@role), headers: as(@owner)
    assert_response :success

    %w[writes bare identity tripwire_ungated inherited_skip_base inherited_skip_child].each do |c|
      assert_select "th[scope=row] .cs-ungated-badge#cs_ungated_#{c}", { count: 1 },
                    "#{c} is provably ungated and must be marked"
    end
    # Gated rows, and the unprovable conditional skip (the reflection stays
    # silent rather than guessing per-action).
    %w[reports admin_reports reasserted_gate conditional_skip].each do |c|
      assert_select "#cs_ungated_#{c}", { count: 0 }, "#{c} must not be marked"
    end
  end

  test "the badge names the fact, scopes its claim to routed actions, and speaks the tripwire's remediation" do
    get current_scope.edit_role_url(@role), headers: as(@owner)

    assert_select ".cs-ungated-badge#cs_ungated_writes", text: /gate not run/
    assert_select ".cs-ungated-badge#cs_ungated_writes", text: /routed actions grants nothing/
    # Each remedy names its cause — re-including Guard is a NO-OP on an
    # inherited-skip subclass (the #62 shape), so the badge must not offer it
    # as the fix for that case. (#69 implementation review, adversarial)
    assert_select ".cs-ungated-badge#cs_ungated_writes", text: /inherited a skip, re-assert/
    assert_select ".cs-ungated-badge#cs_ungated_writes", text: /never had\s+the gate, include CurrentScope::Guard/
    assert_select ".cs-ungated-badge#cs_ungated_writes", text: /current_scope_check!/
  end

  test "a namespaced ungated controller gets a well-formed badge id and aria wiring" do
    get current_scope.edit_role_url(@role), headers: as(@owner)

    # admin/unguarded → cs_ungated_admin_unguarded: the parameterize separator
    # is load-bearing for namespaced paths, and nothing else exercised it.
    assert_select "th[scope=row] .cs-ungated-badge#cs_ungated_admin_unguarded", count: 1
    assert_select "input[data-cs-row-all][aria-describedby=cs_ungated_admin_unguarded]", count: 1
    # No id collisions across the whole page.
    ids = css_select("[id]").map { |n| n["id"] }
    assert_equal ids.size, ids.uniq.size, "duplicate DOM ids: #{ids.tally.select { |_, c| c > 1 }.keys}"
  end

  test "a marked row's checkboxes stay enabled and carry their name and value" do
    get current_scope.edit_role_url(@role), headers: as(@owner)

    assert_select "input#perm_writes_guarded[type=checkbox][name=?][value=?]",
                  "role[permission_keys][]", "writes#guarded" do |els|
      assert_nil els.first["disabled"], "marking is not disabling — the checkbox must stay live"
    end
    assert_select "input#perm_writes_unguarded[type=checkbox][name=?][value=?]",
                  "role[permission_keys][]", "writes#unguarded"
  end

  test "saving a role with a marked controller's key ticked persists it" do
    # The R4/R5 proof: the mark changes presentation, never behavior — the key
    # round-trips through the real RolesController like any other.
    patch current_scope.role_url(@role), headers: as(@owner),
          params: { role: { name: "Editor", full_access: "0", permission_keys: [ "writes#guarded" ] } }
    assert_redirected_to current_scope.roles_path

    assert_includes @role.reload.permission_keys, "writes#guarded"
  end

  test "every control in a marked row is wired to its badge via aria-describedby" do
    get current_scope.edit_role_url(@role), headers: as(@owner)

    # The aria-label is the accessible NAME; describedby is how the warning
    # reaches a screen reader on the row-all toggle and every cell checkbox.
    assert_select "input[data-cs-row-all][aria-label=?][aria-describedby=?]",
                  "Enable all writes permissions", "cs_ungated_writes"
    assert_select "input#perm_writes_guarded[aria-describedby=?]", "cs_ungated_writes"
    assert_select "input#perm_writes_unguarded[aria-describedby=?]", "cs_ungated_writes"
    # A gated row carries no such wiring.
    assert_select "input#perm_reports_read[aria-describedby]", count: 0
  end

  test "break-glass on a marked row is exempt from the badge's claim, and the cell says so" do
    original_allow = CurrentScope.config.allow_sod_bypass
    original_actions = CurrentScope.config.sod_actions
    # "guarded" as an SoD action makes the UNGATED writes controller route one,
    # so the catalog injects writes#bypass_sod onto a marked row (KTD-9: that
    # cell is LIVE — any gated controller deciding SoD on the record honors it).
    CurrentScope.config.allow_sod_bypass = true
    CurrentScope.config.sod_actions = %w[approve guarded]
    CurrentScope.reset_catalog!

    get current_scope.edit_role_url(@role), headers: as(@owner)
    assert_response :success

    assert_select ".cs-ungated-badge#cs_ungated_writes", { count: 1 }, "precondition: writes is marked"
    # The exemption markup: the bypass cell is classed (the CSS hook that keeps
    # the real granted wash) and carries a visible per-cell note.
    assert_select "td.cs-cell-bypass span.cs-bypass-exempt#cs_bypass_exempt_writes",
                  { count: 1, text: /exempt/ }
    # Its checkbox is described by the badge AND the exemption note.
    assert_select "input#perm_writes_bypass_sod[aria-describedby=?]",
                  "cs_ungated_writes cs_bypass_exempt_writes"
    # A gated controller's bypass cell gets no exemption note — nothing to exempt.
    assert_select "input#perm_reports_bypass_sod", { count: 1 }, "precondition: reports breaks glass too"
    assert_select "#cs_bypass_exempt_reports", count: 0
  ensure
    CurrentScope.config.allow_sod_bypass = original_allow
    CurrentScope.config.sod_actions = original_actions
    CurrentScope.reset_catalog!
  end

  test "the mark's limit is stated whenever the grid renders — even with zero marked rows" do
    get current_scope.edit_role_url(@role), headers: as(@owner)
    assert_select "p.cs-ungated-hint", { count: 1, text: /not proof/ }

    # R9: the hint is unconditional. Render against a grid whose reflection
    # marks nothing and it must still be there. (Hand-rolled shadow of ::new —
    # minitest 6 no longer ships minitest/mock.)
    clean = CurrentScope::PermissionGrid.new(gating: Class.new { def ungated?(_) = false }.new)
    CurrentScope::PermissionGrid.define_singleton_method(:new) { |*, **| clean }
    begin
      get current_scope.edit_role_url(@role), headers: as(@owner)
    ensure
      CurrentScope::PermissionGrid.singleton_class.remove_method(:new)
    end
    assert_select ".cs-ungated-badge", { count: 0 }, "precondition: the stubbed grid marks nothing"
    assert_select "p.cs-ungated-hint", { count: 1, text: /not proof/ }
  end

  test "one broken controller renders as uninspectable instead of 500ing the whole editor" do
    # The reflection deliberately propagates a broken controller body's
    # NameError (KTD-2). The VIEW absorbs it per row — one broken controller
    # must not take down the role editor for every other row — while the rake
    # task keeps propagating (its output makes proof claims). The row renders
    # an explicit unknown state: not the danger badge, never silence.
    raising = Class.new {
      def ungated?(controller) = controller == "reports" ? raise(NameError, "boom") : false
    }.new
    grid = CurrentScope::PermissionGrid.new(gating: raising)
    CurrentScope::PermissionGrid.define_singleton_method(:new) { |*, **| grid }
    begin
      get current_scope.edit_role_url(@role), headers: as(@owner)
    ensure
      CurrentScope::PermissionGrid.singleton_class.remove_method(:new)
    end

    assert_response :success
    assert_select ".cs-uninspectable-note#cs_uninspectable_reports", { count: 1, text: /could not inspect/ }
    assert_select "#cs_ungated_reports", { count: 0 }, "unknown must not wear the ungated badge"
    assert_select ".cs-uninspectable-note", { count: 1 }, "only the raising row is affected"
    assert_select "input#perm_reports_read[type=checkbox]", { count: 1 },
                  "the broken row's cells still render and stay tickable"
  end
end
