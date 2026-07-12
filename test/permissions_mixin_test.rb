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
    # SoD is opt-in (empty by default); one test here asserts the :either veto.
    @original_sod_actions = CurrentScope.config.sod_actions
    CurrentScope.config.sod_actions = %w[approve]
  end

  teardown do
    CurrentScope.config.sod_actions = @original_sod_actions
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

  test "under impersonation, allowed_to? and the resolver agree on an actor-initiated record" do
    admin = User.create!(name: "Admin")
    report = Report.create!(title: "Q9", requested_by: admin)   # initiated by the actor
    # @alice already holds an org-wide role (setup); widen it rather than adding
    # a second assignment (one org-wide role per subject).
    CurrentScope::RoleAssignment.find_by(subject: @alice).role
                                .role_permissions.create!(permission_key: "reports#approve")

    # View helper reads the ambient actor and honours the SoD :either veto...
    with_current_user(@alice, actor: admin) do   # admin acts as @alice
      assert_not FakeComponent.new.allowed_to?(:approve, report)
    end

    # ...and the resolver the Guard consults reaches the same verdict + reason.
    allowed, reason = CurrentScope::Resolver.new.decide(
      subject: @alice, permission: "reports#approve", record: report, actor: admin
    )
    assert_not allowed
    assert_equal :sod_veto, reason
  end

  test "with_current_user restores the previous subject" do
    with_current_user(@alice) { nil }
    assert_nil CurrentScope::Current.user
  end
end
