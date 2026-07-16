require "application_system_test_case"

# The "gate not run" badge and its two CSS-only companions are invisible to
# assert_select: the muted hatch on a marked row's checked cell and the
# break-glass cell keeping the real granted wash are computed styles, and the
# grid-header-overlap incident is the proof that green markup tests don't see
# a broken render. This drives the real page. (#69 implementation review)
class UngatedBadgeTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))

    # A grant on the ungated writes controller, so its cell renders checked.
    @editor = CurrentScope::Role.create!(name: "Editor")
    @editor.role_permissions.create!(permission_key: "writes#guarded")
    sign_in(@owner)
  end

  test "the badge renders and a marked row's checked cell hatches while break-glass keeps the wash" do
    original_bypass = CurrentScope.config.allow_sod_bypass
    original_sod = CurrentScope.config.sod_actions
    # Break-glass on + an SoD action routed on ungated writes puts the one
    # LIVE cell on a marked row (KTD-9) — grant it so both washes render.
    CurrentScope.config.allow_sod_bypass = true
    CurrentScope.config.sod_actions = %w[guarded]
    CurrentScope.reset_catalog!
    @editor.role_permissions.create!(permission_key: "writes#bypass_sod")

    visit "/current_scope/roles/#{@editor.id}/edit"
    assert_selector ".cs-ungated-badge", minimum: 1
    assert_selector "#cs_ungated_writes", text: /gate not run/i

    styles = page.evaluate_script(<<~JS)
      (() => {
        const marked = document.querySelector("#cs_ungated_writes").closest("tr");
        const hatched = marked.querySelector("td:not(.cs-cell-bypass) input:checked").closest("td");
        const bypass = marked.querySelector("td.cs-cell-bypass input:checked").closest("td");
        return {
          hatch: getComputedStyle(hatched).backgroundImage,
          bypassImage: getComputedStyle(bypass).backgroundImage,
          bypassColor: getComputedStyle(bypass).backgroundColor,
          exemptNote: !!marked.querySelector("td.cs-cell-bypass .cs-bypass-exempt")
        };
      })()
    JS

    assert_includes styles["hatch"], "repeating-linear-gradient",
                    "a checked cell in a marked row must not wear the granted wash"
    assert_equal "none", styles["bypassImage"],
                 "the live break-glass cell must NOT be hatched (KTD-9)"
    refute_equal "rgba(0, 0, 0, 0)", styles["bypassColor"],
                 "the break-glass cell keeps the real granted wash"
    assert styles["exemptNote"], "the exempt note renders on the bypass cell"

    shot("ungated_badge_states")
  ensure
    CurrentScope.config.allow_sod_bypass = original_bypass
    CurrentScope.config.sod_actions = original_sod
    CurrentScope.reset_catalog!
  end
end
