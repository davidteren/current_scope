require "test_helper"

# Actor resolution runs inside a real request via Context, so it is exercised
# end to end here. config.actor_method is global, so each test sets it and the
# teardown restores the original — no bleed into the rest of the suite.
class ImpersonationContextTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(name: "Admin")
    @member = User.create!(name: "Member")
    @original_actor_method = CurrentScope.config.actor_method
  end

  teardown do
    CurrentScope.config.actor_method = @original_actor_method
  end

  def identity(user: nil, actor: nil)
    headers = {}
    headers["X-User-Id"] = user.id.to_s if user
    headers["X-Actor-Id"] = actor.id.to_s if actor
    get identity_url, headers: headers
    JSON.parse(response.body)
  end

  test "actor defaults to the subject when actor_method is unset" do
    assert_nil CurrentScope.config.actor_method

    body = identity(user: @member)
    assert_equal @member.id, body["user"]
    assert_equal @member.id, body["actor"]
    assert_not body["impersonating"]
  end

  test "actor resolves independently from the subject when actor_method is set" do
    CurrentScope.config.actor_method = :true_user

    body = identity(user: @member, actor: @admin)
    assert_equal @member.id, body["user"]
    assert_equal @admin.id, body["actor"]
    assert body["impersonating"]
  end

  test "a configured but missing actor_method raises instead of silently resolving" do
    CurrentScope.config.actor_method = :no_such_actor_method

    assert_raises(CurrentScope::ConfigurationError) do
      get identity_url, headers: { "X-User-Id" => @member.id.to_s }
    end
  end

  test "actor does not bleed between requests" do
    CurrentScope.config.actor_method = :true_user

    first = identity(user: @member, actor: @admin)
    assert_equal @admin.id, first["actor"]

    # Second request carries no actor header; a reset context must fall back to
    # the subject, never reuse the previous request's actor.
    second = identity(user: @member)
    assert_equal @member.id, second["actor"]
    assert_not second["impersonating"]
  end
end
