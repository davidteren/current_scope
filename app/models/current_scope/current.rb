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

    # Falls back to the effective subject, so actor is never nil when user is
    # set — callers attribute to `actor` without a nil branch.
    def actor
      super || user
    end
  end
end
