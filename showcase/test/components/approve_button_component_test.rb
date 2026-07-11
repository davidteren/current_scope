require "test_helper"
require "view_component/test_case"
require "current_scope/test_helpers"

# Proves the ambient context reaches components with no current_user threading.
class ApproveButtonComponentTest < ViewComponent::TestCase
  include CurrentScope::TestHelpers

  setup do
    @report = reports(:one)   # requested by users(:one)
    @reviewer = users(:two)
    role = CurrentScope::Role.create!(name: "Reviewer")
    role.update!(permission_keys: %w[reports#approve])
    CurrentScope::RoleAssignment.create!(subject: @reviewer, role: role)
  end

  test "renders for a reviewer" do
    with_current_user(@reviewer) do
      render_inline ApproveButtonComponent.new(record: @report)
      assert_selector "form button", text: "Approve"
    end
  end

  test "does not render without the permission" do
    with_current_user(users(:one)) do
      render_inline ApproveButtonComponent.new(record: @report)
      assert_no_selector "button"
    end
  end

  test "does not render for the requester (SoD), even with the permission" do
    role = CurrentScope::Role.create!(name: "ReviewerToo")
    role.update!(permission_keys: %w[reports#approve])
    CurrentScope::RoleAssignment.create!(subject: users(:one), role: role)

    with_current_user(users(:one)) do
      render_inline ApproveButtonComponent.new(record: @report)
      assert_no_selector "button"
    end
  end

  test "does not render with no ambient user at all" do
    render_inline ApproveButtonComponent.new(record: @report)
    assert_no_selector "button"
  end

  test "does not render when already approved" do
    @report.approve!(by: @reviewer)
    with_current_user(@reviewer) do
      render_inline ApproveButtonComponent.new(record: @report)
      assert_no_selector "button"
    end
  end
end
