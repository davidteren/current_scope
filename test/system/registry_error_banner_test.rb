require "application_system_test_case"

# #166 — a poisoned polymorphic registry must degrade the console, not 500 it.
# In a real browser, because the banner is new markup and the whole point is that
# an operator can still READ this page: the banner has to be visible, has to say
# why, and must not push the inert rows off the screen.
class RegistryErrorBannerTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(name: "Olivia Owner")
    CurrentScope::RoleAssignment.create!(
      subject: @owner, role: CurrentScope::Role.create!(name: "Owner", full_access: true))
    @role = CurrentScope::Role.create!(name: "Editor")
    @original_polymorphic_names = CurrentScope.config.polymorphic_class_names
    sign_in(@owner)
  end

  teardown do
    CurrentScope.config.polymorphic_class_names = @original_polymorphic_names
    CurrentScope.rebuild_polymorphic_registry!
  end

  test "the members page renders a registry banner and inert rows instead of 500ing" do
    folder = Folder.create!(name: "Space")
    bob = User.create!(name: "Bob")
    # Before the poison: the write path stays fail-closed, so this row could not
    # be created afterwards. That refusal is pinned in role_members_test.rb.
    sra = CurrentScope::ScopedRoleAssignment.create!(subject: bob, resource: folder, role: @role)

    CurrentScope.config.polymorphic_class_names = { "old_token" => "User" }
    error = assert_raises(CurrentScope::ConfigurationError) { CurrentScope.rebuild_polymorphic_registry! }
    assert_match(/old_token/, error.message,
                 "the poison must raise from THIS token mismatch, not a latch a previous test left behind")

    visit "/current_scope/roles/#{@role.id}/members"

    assert_selector "#cs-registry-error", text: /Registry misconfigured/i
    assert_selector "#cs-registry-error", text: /old_token/
    assert_selector "#scoped_holder_#{sra.id}.cs-row--inert"

    # The banner is an alert for a screen reader, like the flash it sits beside.
    assert_equal "alert", find("#cs-registry-error")[:role]

    # It must be on screen, not merely in the DOM: this is the page an operator
    # opened to diagnose the very problem it names.
    assert page.evaluate_script(<<~JS), "the registry banner must be visible"
      (() => {
        const el = document.querySelector("#cs-registry-error");
        const style = getComputedStyle(el);
        const box = el.getBoundingClientRect();
        // Intersects the viewport, not merely "has a box": an element scrolled
        // entirely off screen still reports a nonzero width and height.
        return style.display !== "none" && style.visibility !== "hidden" &&
               box.height > 0 && box.width > 0 &&
               box.bottom > 0 && box.right > 0 &&
               box.top < window.innerHeight && box.left < window.innerWidth;
      })()
    JS

    shot("registry_error_banner")
  end
end
