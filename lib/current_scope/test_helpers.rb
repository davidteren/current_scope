module CurrentScope
  # Test support for host apps:
  #
  #   include CurrentScope::TestHelpers
  #
  #   with_current_user(users(:alice)) do
  #     assert component_allows_approve?
  #   end
  #
  #   with_current_user(users(:bob), actor: users(:admin)) do   # act-as
  #     assert impersonating?
  #   end
  #
  # CurrentAttributes resets between examples, so nothing set here can leak.
  module TestHelpers
    # Snapshot/restore the RAW attributes rather than using Current.set: the
    # actor reader falls back to user, and Object#with (which set uses) would
    # snapshot that fallback and restore a stale actor. Saving the underlying
    # hash restores the true prior state.
    def with_current_user(user, actor: nil)
      previous = CurrentScope::Current.attributes
      CurrentScope::Current.user = user
      CurrentScope::Current.actor = actor
      yield
    ensure
      CurrentScope::Current.attributes = previous
    end
  end
end
