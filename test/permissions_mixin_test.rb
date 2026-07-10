require "test_helper"
require "current_scope/test_helpers"

# A stand-in for any PORO/component that mixes in the portable helper.
class FakeComponent
  include CurrentScope::Permissions
end

class PermissionsMixinTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  setup do
    @alice = User.create!(name: "Alice")
    @report = Report.create!(title: "Q3", requested_by: @alice)
    reviewer = CurrentScope::Role.create!(name: "Reviewer")
    reviewer.role_permissions.create!(permission_key: "reports#show")
    CurrentScope::RoleAssignment.create!(subject: @alice, role: reviewer)
  end

  test "allowed_to? reads the ambient subject — no threading required" do
    component = FakeComponent.new

    with_current_user(@alice) do
      assert component.allowed_to?(:show, @report)
      assert_not component.allowed_to?(:destroy, @report)
    end
  end

  test "no ambient subject means denied" do
    assert_not FakeComponent.new.allowed_to?(:show, @report)
  end

  test "with_current_user restores the previous subject" do
    with_current_user(@alice) { nil }
    assert_nil CurrentScope::Current.user
  end
end
