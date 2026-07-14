require "test_helper"
require "current_scope/test_helpers"

# A2: the impersonation-boundary API is the one seam where a host declares it is
# actually impersonating. If config.actor_method is unset at that moment, the
# whole act-as security model is inert (dead MutationGuard, dead SoD :either,
# mis-attributed audit) — so the boundary API fails LOUD rather than silently
# recording an impersonation with no real actor behind it.
class ImpersonationBoundaryTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  setup do
    @actor = User.create!(name: "Admin")
    @subject = User.create!(name: "Impersonated")
    @original_actor_method = CurrentScope.config.actor_method
  end

  teardown do
    CurrentScope.config.actor_method = @original_actor_method
  end

  test "record_impersonation_started! raises when actor_method is unset" do
    # Ambient actor is present, so the ONLY misconfiguration is the missing
    # actor_method — proving the check is about actor_method, not a nil actor.
    with_current_user(@actor) do
      CurrentScope.config.actor_method = nil
      error = assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope.record_impersonation_started!(@subject)
      end
      assert_match(/actor_method/, error.message)
    end
  end

  test "record_impersonation_stopped! raises when actor_method is unset" do
    with_current_user(@actor) do
      CurrentScope.config.actor_method = nil
      assert_raises(CurrentScope::ConfigurationError) do
        CurrentScope.record_impersonation_stopped!(@subject)
      end
    end
  end

  test "record_impersonation_started! records normally when actor_method is set" do
    CurrentScope.config.actor_method = :true_user
    with_current_user(@actor) do
      assert_difference -> { CurrentScope::Event.count }, 1 do
        CurrentScope.record_impersonation_started!(@subject)
      end
    end
  end
end
