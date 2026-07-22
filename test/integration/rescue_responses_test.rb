require "test_helper"

# #39 — escaped AccessDenied must classify as 403, not 500.
class RescueResponsesTest < ActionDispatch::IntegrationTest
  test "engine registers AccessDenied as :forbidden in rescue_responses" do
    responses = ActionDispatch::ExceptionWrapper.rescue_responses
    assert_equal :forbidden, responses["CurrentScope::AccessDenied"],
      "escaped denials must not become 500s"
  end

  test "config and ExceptionWrapper both carry the AccessDenied mapping" do
    # Belt: after: action_dispatch.configure also pins ExceptionWrapper so a
    # Rails upgrade that renames the framework initializer cannot leave the
    # class unmapped even if config merge is skipped.
    assert_equal :forbidden,
      Rails.application.config.action_dispatch.rescue_responses["CurrentScope::AccessDenied"]
    assert_equal :forbidden,
      ActionDispatch::ExceptionWrapper.rescue_responses["CurrentScope::AccessDenied"]
  end

  test "an AccessDenied outside Guard rescue returns 403 not 500" do
    # BareDenyController has no MutationGuard rescue_from — status only.
    get bare_deny_url
    assert_response :forbidden
    assert_not_equal 500, response.status
    assert_nil response.headers["X-Current-Scope-Reason"],
      "escaped denials do not run current_scope_denied"
  end
end
