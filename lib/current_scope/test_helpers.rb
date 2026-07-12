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

    # Seed a real org-wide grant for request/system specs. Unlike
    # with_current_user (which only sets Current.user in-process, and is
    # overwritten by Context's before_action on a real request), this persists a
    # RoleAssignment row that survives the request cycle, so a host can test its
    # own controllers behind the gate. It does NOT authenticate — the host still
    # signs the subject in through its own auth. Bang-suffixed like the engine's
    # other DB-mutating helpers (seed_defaults!, Event.record!). Returns the
    # assignment.
    def grant_role!(subject, role:)
      CurrentScope::RoleAssignment.create!(subject: subject, role: role)
    end

    # The scoped-grant companion: seed a role held on ONE specific record.
    # Returns the scoped assignment.
    def grant_scoped_role!(subject, role:, record:)
      CurrentScope::ScopedRoleAssignment.create!(subject: subject, role: role, resource: record)
    end
  end
end
