require "test_helper"

class ManagementAuthorizerTest < ActiveSupport::TestCase
  test "invalid management configuration raises even without a subject" do
    original = CurrentScope.config.management_authorizer
    CurrentScope.config.management_authorizer = Object.new

    error = assert_raises(CurrentScope::ConfigurationError) do
      CurrentScope.can_manage?(:access, subject: nil)
    end
    assert_equal "management_authorizer must respond to call", error.message

    calls = []
    CurrentScope.config.management_authorizer = ->(*) { calls << true }
    assert_not CurrentScope.can_manage?(:access, subject: nil)
    assert_empty calls
  ensure
    CurrentScope.config.management_authorizer = original
  end
end
