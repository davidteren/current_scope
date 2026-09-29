require "application_system_test_case"

# Browser proof that known console controls follow the delegated policy (#210).
# :access is allowed. :update_role and :revoke_role are denied. A separate
# example allows :revoke_role so a permitted clear still submits.
class DelegatedConsoleControlsTest < ApplicationSystemTestCase
  EDIT_HINT = "Your administration permissions do not allow editing this role."
  REMOVAL_HINT = "Your administration permissions do not allow this removal."

  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @delegate = User.create!(name: "Delegate")
    @editor = CurrentScope::Role.create!(name: "Editor")
    @alice = User.create!(name: "Alice Holder")
    @assignment = CurrentScope::RoleAssignment.create!(subject: @alice, role: @editor)
    @folder = Folder.create!(name: "Plans")
    @scoped = CurrentScope::ScopedRoleAssignment.create!(
      subject: @alice, resource: @folder, role: @editor)
    @prior_authorizer = CurrentScope.config.management_authorizer
    sign_in(@delegate)
  end

  teardown do
    CurrentScope.config.management_authorizer = @prior_authorizer
  end

  test "denied known controls show a disabled state and a hint beside them" do
    CurrentScope.config.management_authorizer = ->(subject, action:, **) {
      subject == @delegate && action == :access
    }

    visit members_path
    assert_rendered
    assert_operator page.evaluate_script("window.innerWidth"), :>, 820

    assert_selector "span#edit_permissions", text: "Edit permissions"
    assert_no_selector "a#edit_permissions"
    assert_selector "#edit_permissions_limit", text: EDIT_HINT
    assert_selector disabled_control("org_clear_#{@assignment.id}")
    assert_selector "#org_clear_#{@assignment.id}_limit", text: REMOVAL_HINT
    assert_no_selector "#org_remove_#{@assignment.id}"
    assert_selector disabled_control("scoped_revoke_#{@scoped.id}")
    assert_selector "#scoped_revoke_#{@scoped.id}_limit", text: REMOVAL_HINT
    assert_selector "#subject_gids option:not([disabled])"
    assert_no_selector "#subject_gids option[disabled]"

    assert_hint_beside("#edit_permissions", "#edit_permissions_limit")
    assert_hint_beside("#org_clear_#{@assignment.id}", "#org_clear_#{@assignment.id}_limit")
    assert_hint_beside("#scoped_revoke_#{@scoped.id}", "#scoped_revoke_#{@scoped.id}_limit")

    page.execute_script("document.querySelector('#org_clear_#{@assignment.id}').click()")
    assert_equal members_path, page.current_path
    assert_no_selector ".cs-flash--notice", text: "Org-wide role cleared"
    assert CurrentScope::RoleAssignment.exists?(@assignment.id)

    current_window.resize_to(500, 900)
    assert_operator page.evaluate_script("window.innerWidth"), :<=, 820
    assert_hint_beside("#edit_permissions", "#edit_permissions_limit")
    assert_hint_beside("#org_clear_#{@assignment.id}", "#org_clear_#{@assignment.id}_limit")
    assert_hint_beside("#scoped_revoke_#{@scoped.id}", "#scoped_revoke_#{@scoped.id}_limit")

    visit "/current_scope/subjects"
    assert_rendered
    assert_selector disabled_control("scoped_chip_revoke_#{@scoped.id}")
    assert_selector "#scoped_chip_revoke_#{@scoped.id}_limit", text: REMOVAL_HINT
    assert_includes find("#scoped_chip_revoke_#{@scoped.id}")["aria-label"], @editor.name
    assert_hint_beside("#scoped_chip_revoke_#{@scoped.id}", "#scoped_chip_revoke_#{@scoped.id}_limit")

    current_window.resize_to(1280, 900)
    assert_operator page.evaluate_script("window.innerWidth"), :>, 820
    assert_hint_beside("#scoped_chip_revoke_#{@scoped.id}", "#scoped_chip_revoke_#{@scoped.id}_limit")
  ensure
    current_window.resize_to(1280, 900)
  end

  test "an allowed clear still removes the org-wide role" do
    CurrentScope.config.management_authorizer = ->(subject, action:, **) {
      subject == @delegate && %i[access revoke_role].include?(action)
    }

    visit members_path
    assert_rendered
    assert_selector "#org_clear_#{@assignment.id}:not([disabled])"
    assert_no_selector "#org_clear_#{@assignment.id}_limit"

    click_button "org_clear_#{@assignment.id}"

    assert_selector ".cs-flash--notice", text: "Org-wide role cleared."
    assert_not CurrentScope::RoleAssignment.exists?(@assignment.id)
  end

  private

  def members_path
    "/current_scope/roles/#{@editor.id}/members"
  end

  def disabled_control(id)
    "##{id}[disabled][aria-describedby='#{id}_limit']"
  end

  # The hint has to be on screen, and close to the control, at this viewport.
  # Capybara visible is not the same as inside the window.
  def assert_hint_beside(control_id, hint_id)
    metrics = page.evaluate_script(<<~JS)
      (() => {
        const control = document.querySelector(#{control_id.to_json});
        const hint = document.querySelector(#{hint_id.to_json});
        if (!control || !hint) return { missing: true };
        control.scrollIntoView({ block: "center", inline: "center" });
        const a = control.getBoundingClientRect();
        const b = hint.getBoundingClientRect();
        const seen = (box) => box.height > 0 && box.width > 0 &&
          box.bottom > 0 && box.right > 0 &&
          box.top < window.innerHeight && box.left < window.innerWidth;
        const gapX = Math.max(0, Math.max(a.left, b.left) - Math.min(a.right, b.right));
        const gapY = Math.max(0, Math.max(a.top, b.top) - Math.min(a.bottom, b.bottom));
        return { missing: false, controlSeen: seen(a), hintSeen: seen(b),
                 gapX: gapX, gapY: gapY, gap: Math.hypot(gapX, gapY) };
      })()
    JS

    assert metrics["controlSeen"], "#{control_id} must be on screen (#{metrics.inspect})"
    assert metrics["hintSeen"], "#{hint_id} must be on screen (#{metrics.inspect})"
    assert_operator metrics["gap"].to_f, :<, 80,
      "#{hint_id} must sit next to #{control_id} (#{metrics.inspect})"
  end
end
