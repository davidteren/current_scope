require "test_helper"
require "current_scope/test_helpers"

class CurrentTest < ActiveSupport::TestCase
  include CurrentScope::TestHelpers

  setup do
    @user = User.create!(name: "User")
    @actor = User.create!(name: "Actor")
  end

  test "actor falls back to the effective subject when unset" do
    CurrentScope::Current.user = @user
    assert_equal @user, CurrentScope::Current.actor
  end

  test "actor is independent of user when explicitly set" do
    CurrentScope::Current.set(user: @user, actor: @actor) do
      assert_equal @user, CurrentScope::Current.user
      assert_equal @actor, CurrentScope::Current.actor
    end
  end

  test "with_current_user sets the actor/subject pair and restores after the block" do
    with_current_user(@user, actor: @actor) do
      assert_equal @user, CurrentScope::Current.user
      assert_equal @actor, CurrentScope::Current.actor
    end
    assert_nil CurrentScope::Current.user
    assert_nil CurrentScope::Current.attributes[:actor]
  end

  test "with_current_user still works with a single subject and actor falls back to it" do
    with_current_user(@user) do
      assert_equal @user, CurrentScope::Current.user
      assert_equal @user, CurrentScope::Current.actor
    end
  end

  test "actor does not leak between examples" do
    assert_nil CurrentScope::Current.user
    assert_nil CurrentScope::Current.attributes[:actor]
  end

  test "impersonating? is false when no distinct actor is present" do
    component = Class.new { include CurrentScope::Permissions }.new
    with_current_user(@user) do
      assert_not component.impersonating?
    end
    with_current_user(@user, actor: @actor) do
      assert component.impersonating?
    end
  end
end
