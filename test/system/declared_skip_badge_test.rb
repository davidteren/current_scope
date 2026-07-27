require "application_system_test_case"

# #76 — declared skip badge in a real browser (layout + CSS weight).
class DeclaredSkipBadgeTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @editor = CurrentScope::Role.create!(name: "Editor")
    sign_in(@owner)
  end

  test "the declared-skip badge renders with the reason and normal font weight" do
    visit "/current_scope/roles/#{@editor.id}/edit"

    assert_selector "#cs_declared_skip_declared_skip", text: /skipped/i
    assert_selector "#cs_declared_skip_declared_skip", text: /public health-check endpoint/i
    assert_no_selector "#cs_ungated_declared_skip"

    weight = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("#cs_declared_skip_declared_skip");
        return getComputedStyle(el).fontWeight;
      })()
    JS
    # 400 (or "normal") — not bold from the parent th.
    assert_includes %w[400 normal], weight.to_s.downcase,
                    "declared-skip body text must not inherit th bold"

    shot("declared_skip_badge")
  end
end
