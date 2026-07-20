require "test_helper"

# #39 — escaped AccessDenied must classify as 403, not 500.
class RescueResponsesTest < ActionDispatch::IntegrationTest
  test "engine registers AccessDenied as :forbidden in rescue_responses" do
    responses = ActionDispatch::ExceptionWrapper.rescue_responses
    assert_equal :forbidden, responses["CurrentScope::AccessDenied"],
      "escaped denials must not become 500s"
  end

  test "an AccessDenied outside Guard rescue returns 403 not 500" do
    # BareController includes only Context — no MutationGuard rescue_from.
    get bare_deny_url
    assert_response :forbidden
    assert_not_equal 500, response.status
  end
end
