require "application_system_test_case"

# #43 — "no controller" badge for routes whose class is missing. The hatch on
# a checked phantom cell is CSS-only, so assert_select cannot see it.
class MissingControllerBadgeTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @editor = CurrentScope::Role.create!(name: "Editor")
    # Pre-grant so the orphaned row's read cell is checked and can hatch.
    @editor.role_permissions.create!(permission_key: "orphaned#index")
    sign_in(@owner)
  end

  test "the no-controller badge renders and a checked phantom cell hatches" do
    visit "/current_scope/roles/#{@editor.id}/edit"

    assert_selector "#cs_missing_controller_orphaned", text: /no controller/i
    assert_selector "#cs_missing_controller_orphaned", text: /stale or typo route/i

    styles = page.evaluate_script(<<~JS)
      (() => {
        const marked = document.querySelector("#cs_missing_controller_orphaned").closest("tr");
        const checked = marked.querySelector("td input:checked");
        if (!checked) return { hatch: null };
        const cell = checked.closest("td");
        return { hatch: getComputedStyle(cell).backgroundImage };
      })()
    JS

    assert styles["hatch"], "orphaned read cell should be checked from setup grant"
    assert_includes styles["hatch"], "repeating-linear-gradient",
                    "a checked cell on a no-controller row must not wear the live-grant wash"

    shot("missing_controller_badge")
  end
end
