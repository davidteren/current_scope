module CurrentScope
  # Test support for host apps:
  #
  #   include CurrentScope::TestHelpers
  #
  #   with_current_user(users(:alice)) do
  #     assert component_allows_approve?
  #   end
  #
  # CurrentAttributes resets between examples, so nothing set here can leak.
  module TestHelpers
    def with_current_user(user, &block)
      CurrentScope::Current.set(user: user, &block)
    end
  end
end
