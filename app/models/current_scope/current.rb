module CurrentScope
  # The ambient authorization context. Request- and job-scoped: Rails resets
  # CurrentAttributes around every unit of execution, so the subject can never
  # leak between requests, jobs, or test examples.
  #
  # Two identities live here:
  #   - user  — the EFFECTIVE subject every permission check reads.
  #   - actor — the REAL principal behind the request (the pretender's
  #             `true_user`). It falls back to `user`, so attribution always
  #             reads `actor` with no nil branch. They differ only while
  #             impersonating: actor = the admin, user = the impersonated subject.
  class Current < ActiveSupport::CurrentAttributes
    # request_id is correlation-only metadata the audit recorder stamps onto
    # each event; nil when the host hasn't set it. Additive — no reader override.
    attribute :user, :actor, :request_id

    # Per-request memo for the resolver's org-role lookup. A view with N
    # permission-gated elements calls the gate N times, each otherwise re-running
    # the same `RoleAssignment.find_by(subject:)`; caching it here collapses that
    # to one query. Request/job-scoped like everything on CurrentAttributes, so
    # it never leaks across requests, and invalidated on any org-role write (see
    # RoleAssignment) so a grant-then-check within one request is never stale.
    attribute :org_role_cache

    # Falls back to the effective subject, so actor is never nil when user is
    # set — callers attribute to `actor` without a nil branch.
    #
    # ROUND-TRIP HAZARD: the reader answers with the fallback, not stored
    # state. Snapshot/restore code (Current.set, Object#with, anything that
    # reads #actor to write it back) would pin the fallback as an explicit
    # actor and restore a stale identity once user changes — read the raw
    # `attributes` hash instead, as TestHelpers#with_current_user does.
    def actor
      super || user
    end

    # True only while a distinct real actor stands behind the effective
    # subject (act-as). THE definition of "impersonating" — the Permissions
    # mixin and the mutation guard both delegate here, so the view-level
    # read-only signal and the write gate can never drift apart.
    def impersonating?
      user.present? && actor != user
    end

    # Memoize the org-role lookup for `subject` for the rest of this request/job.
    # Keyed by subject so a check that spans several subjects stays correct.
    # Caches nil (no role) too, so a repeated "no grant" check is one query, not N.
    def memoized_org_role(subject)
      return yield if subject.nil?

      cache = (self.org_role_cache ||= {})
      key = [ subject.class.name, subject.id ]
      return cache[key] if cache.key?(key)

      cache[key] = yield
    end

    # Drop the memo — called on any org-role write so a later check in the same
    # request sees the change.
    def reset_org_role_cache
      self.org_role_cache = nil
    end
  end
end
