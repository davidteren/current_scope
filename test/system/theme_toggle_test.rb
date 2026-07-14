require "application_system_test_case"

# Light/dark toggle — live flip, namespaced-cookie persistence, and
# server-rendered restore on the next request (no flash).
class ThemeToggleSystemTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    sign_in(@owner)
  end

  test "the toggle flips the theme, persists it, and syncs aria-pressed" do
    visit "/current_scope/roles"
    find("[data-cs-theme-toggle]").click

    chosen = page.evaluate_script("document.documentElement.getAttribute('data-cs-theme')")
    assert_includes %w[light dark], chosen

    assert_match "current_scope_theme=#{chosen}", page.evaluate_script("document.cookie")
    pressed = page.evaluate_script("document.querySelector('[data-cs-theme-toggle]').getAttribute('aria-pressed')")
    assert_equal (chosen == "dark").to_s, pressed
  end

  test "the chosen theme is restored from the cookie on the next request" do
    visit "/current_scope/roles"
    find("[data-cs-theme-toggle]").click
    chosen = page.evaluate_script("document.documentElement.getAttribute('data-cs-theme')")

    visit "/current_scope/subjects" # fresh request
    rendered = page.evaluate_script("document.documentElement.getAttribute('data-cs-theme')")
    assert_equal chosen, rendered, "the theme was not server-rendered from the cookie"
  end
end
