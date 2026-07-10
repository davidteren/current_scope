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
    attr_accessor :allow_mutations_while_impersonating

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

    # When true (the default), CurrentScope::Event.record! appends a row to the
    # append-only audit ledger for every recorded authorization event. When
    # false, record! is a silent no-op — hosts that don't want the ledger set
    # this and skip the events migration.
    attr_accessor :audit

    def initialize
      @user_method = :current_user
      @actor_method = nil
      @sod_actions = %w[approve]
      @sod_identity = :either
      @allow_mutations_while_impersonating = false
      @excluded_controllers = [
        %r{\Arails/}, %r{\Aactive_storage/}, %r{\Aaction_mailbox/},
        %r{\Aturbo/}, %r{\Acurrent_scope/}
      ]
      @parent_controller = "::ApplicationController"
      @subject_class = "User"
      @audit = true
    end
  end
end
