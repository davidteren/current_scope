module CurrentScope
  class Configuration
    # Host controller method that returns the authenticated subject.
    attr_accessor :user_method

    # Host controller method returning the REAL actor while impersonating
    # (the pretender's true_user). nil means actor == user (no impersonation),
    # so the actor is never resolved and falls back to the subject.
    attr_accessor :actor_method

    # Action names subject to the separation-of-duties veto: whoever initiated
    # a record can never perform these actions on it. Not editable in the UI
    # by design — SoD is a structural guarantee, not a preference. Records hit
    # by these actions must define current_scope_initiator (return nil to
    # exempt a record type).
    #
    # EMPTY BY DEFAULT — SoD is opt-in. The engine's baseline is scoped RBAC;
    # many hosts want nothing to do with four-eyes. Enable it by listing the
    # actions to gate, e.g. `config.sod_actions = %w[approve]`.
    attr_accessor :sod_actions

    # Which identities the separation-of-duties veto weighs:
    #   :either  (default) — veto if the effective subject OR (while
    #                        impersonating) the REAL actor initiated the record,
    #                        so impersonation can never approve the actor's own
    #                        record.
    #   :subject           — veto only on the effective subject.
    # The two are identical when not impersonating (actor == subject).
    attr_accessor :sod_identity

    # When false (the default), an impersonated session is read-only: any
    # non-GET/HEAD request is denied while a real actor acts as a different
    # subject — INCLUDING the engine's own management UI. The host's
    # stop-impersonation, sign-out, and sign-in endpoints must opt out with
    # skip_before_action :current_scope_mutation_guard!, or impersonation can
    # never end. The gate runs BEFORE the permission check, so sod_identity is
    # only observable once mutations are allowed (or on a GET-listed sod_action).
    #
    # Setting this true is refused in production unless the env opt-in below is
    # set — letting a real actor write as someone else is a privilege-escalation
    # and audit-integrity risk, so a prod deploy must acknowledge it explicitly.
    # See the custom writer.
    attr_reader :allow_mutations_while_impersonating

    # Env var that opts a PRODUCTION deploy into impersonated writes. Any value
    # (even "false" or "0" — presence is what counts) lifts the production
    # refusal; unset in production means allow_mutations_while_impersonating=true
    # raises at boot. development/test/staging never consult it.
    PROD_MUTATIONS_ENV = "CURRENT_SCOPE_ALLOW_PROD_IMPERSONATION_MUTATIONS"

    # Regexps matched against controller paths to keep infrastructure
    # controllers out of the permission grid. An excluded controller cannot be
    # granted, so it must also skip the gate
    # (skip_before_action :current_scope_check!) — Guard raises otherwise.
    attr_accessor :excluded_controllers

    # Class the management UI's controllers inherit from, so they pick up the
    # host's authentication and layout.
    attr_accessor :parent_controller

    # Host class acting as the subject, used by the management UI to list
    # assignable subjects.
    attr_accessor :subject_class

    # Tri-state: false | true (default) | :strict — controls
    # CurrentScope::Event.record!.
    #   false   — record! is a silent no-op; hosts that don't want the ledger
    #             set this and skip the events migration.
    #   true    — append a row for every event; if the current_scope_events
    #             table hasn't been migrated yet, degrade gracefully (skip +
    #             warn once), so an existing host never breaks on first mutation.
    #   :strict — an audit-mandatory host: a missing events table RAISES instead
    #             of degrading, so a mutation-wrapping transaction rolls back
    #             rather than committing an unaudited grant. (Impersonation-
    #             boundary events have no mutation to roll back — a raise there
    #             is a loud 500 on a mis-migrated host.)
    # Read as `== :strict`, never `== true` — don't flatten the tri-state.
    attr_accessor :audit

    # A5 (opt-in, dev/test aid): when true, the gate logs a nudge if an SoD
    # action is gated with a nil record and the request is allowed — i.e. the
    # SoD veto was silently skipped because current_scope_record returned nil on
    # a member action. Off by default; prod behavior never changes. Emitted from
    # the Guard seam (not the shared resolver), so it doesn't fire on advisory
    # allowed_to?/scope_for calls.
    attr_accessor :warn_on_nil_sod_record

    def initialize
      @user_method = :current_user
      @actor_method = nil
      @sod_actions = []
      @sod_identity = :either
      @allow_mutations_while_impersonating = false
      @excluded_controllers = [
        %r{\Arails/}, %r{\Aactive_storage/}, %r{\Aaction_mailbox/},
        %r{\Aturbo/}, %r{\Acurrent_scope/}
      ]
      @parent_controller = "::ApplicationController"
      @subject_class = "User"
      @audit = true
      @warn_on_nil_sod_record = false
    end

    # Guarded writer: enabling impersonated writes is fine in
    # development/test/staging, but refused in production unless PROD_MUTATIONS_ENV
    # is set — so an unsafe flag fails the deploy loudly at boot instead of
    # silently letting a real actor mutate data as someone else. Assigning false
    # (or leaving the default) is always allowed.
    def allow_mutations_while_impersonating=(value)
      if value && production? && !ENV.key?(PROD_MUTATIONS_ENV)
        raise ConfigurationError,
              "config.allow_mutations_while_impersonating = true is refused in " \
              "production: letting a real actor write as the subject they " \
              "impersonate is a privilege-escalation and audit-integrity risk. " \
              "Keep it false so impersonated sessions stay read-only in " \
              "production, or — only if writes under act-as are genuinely " \
              "required (e.g. a live public showcase) — set ENV[\"#{PROD_MUTATIONS_ENV}\"] " \
              "to opt in explicitly. development, test, and staging are unaffected."
      end
      @allow_mutations_while_impersonating = value
    end

    private

    def production?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
    end
  end
end
