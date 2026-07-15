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

    # How a subject is identified in the management UI (subjects table, picker,
    # bulk bar). A subject id is meaningless with UUID keys, so pick something
    # human. Accepts:
    #   - a Symbol — a method on the subject, e.g. :email or :name
    #   - a Proc   — subject -> String, e.g. ->(u) { "#{u.first_name} #{u.last_name}" }
    #   - nil (default) — best-effort, people-first: email, else name, else
    #     first+last, else the generic current_scope_label / "Class #id".
    #
    # A Proc should be TOTAL — it runs for every subject the admin can see,
    # including ones with nil or blank attributes, so `->(u) { u.email.upcase }`
    # is a trap the first time someone is invited but hasn't filled in an email.
    # Nothing here is load-bearing enough to break a page over, so a label that
    # raises (or a Symbol the subject can't answer) degrades to the default chain
    # for that subject and logs once — it never errors the page and never affects
    # an authorization decision. If subject labels look wrong, check the log:
    # a silent fallback is exactly what a broken label looks like from the UI.
    attr_accessor :subject_label

    # Break-glass override for the SoD veto. Default false — OFF preserves v0.1
    # exactly: the separation-of-duties veto is absolute and this hook is never
    # consulted. When true, the veto is lifted for a record ONLY when all three
    # hold, re-checked live at decision time: this flag is on, the record's
    # `current_scope_sod_bypassed?` hook returns true, AND the record's initiator
    # holds the bypass permission (sod_bypass_permission). Every lifted veto is
    # recorded by the engine (`sod.bypassed`) and surfaced on
    # X-Current-Scope-Reason.
    #
    # HONEST FRAMING: this converts SoD from a *structural* guarantee into an
    # *audited policy override* — it's break-glass, not SoD. Its legitimacy rests
    # on being default-off, privilege-gated, and always audited. Unlike
    # allow_mutations_while_impersonating there is NO production env-gate: the
    # feature is per-record, privilege-scoped, and audited-by-construction, so
    # production is its intended home.
    attr_accessor :allow_sod_bypass

    # The grantable permission the record's initiator must hold for a break-glass
    # bypass to lift the veto (default "bypass_sod"). Resolved against the
    # record's route key like any permission, so it's editable in the role grid —
    # never a hardcoded role. Must NOT be listed in sod_actions (it isn't an SoD
    # action; keeping it out also bounds the bypass re-entrancy).
    #
    # It isn't a routable action, so the catalog injects it rather than deriving
    # it: the grid shows a column for it ONLY when allow_sod_bypass is on, and
    # only on controllers that route an action listed in sod_actions. With the
    # flag off it isn't grantable at all — nothing to tick, and the key is
    # rejected if assigned. (#21)
    attr_accessor :sod_bypass_permission

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

    # How the role-editor grid folds RESTful actions into columns. An ordered
    # Hash of { column_label => [action names] }: ticking a group column grants
    # every routed action in it. The default collapses the seven RESTful verbs
    # into CRUD — new/create and edit/update pair up (the "new"/"edit" actions
    # just render the form for their mutation), index+show read as one. Actions
    # not in any group (e.g. "approve") get their own column. Set to nil (or {})
    # to show every raw action as its own column instead. Either way the grid
    # renders ALIGNED columns — a controller that doesn't route a column's
    # actions shows a blank cell, never a shifted one.
    attr_accessor :permission_grid_groups

    # :enforce (default) | :report — what the gate DOES with a denial. (#37)
    #
    # The adoption ramp. A host retrofitting this engine onto an existing app
    # has a controller suite that goes red the moment the gate is mounted: it is
    # fail-closed, and nothing is granted yet. Report mode lets them mount the
    # gate, run their app, and read what WOULD have been denied out of the
    # ledger — turning a big-bang cutover into a list of grants to seed.
    #
    #   :enforce — deny means 403. The only production posture.
    #   :report  — a MISSING GRANT is logged and allowed through instead. Every
    #              other denial still refuses.
    #
    # Report mode is NOT an off switch and never reaches the things that would
    # make it one: the separation-of-duties veto still refuses, and the
    # management console answers to its own full-access check rather than this
    # gate, so no enforcement setting can hand out the UI where grants are made.
    attr_reader :enforcement

    ENFORCEMENT_MODES = %i[enforce report].freeze

    # Validating writer: an unknown value here is the worst kind of config
    # mistake — the host believes it is enforcing while it is not. Fail at boot,
    # naming what's allowed. Accepts a String so ENV["..."] works; anything that
    # can't be a mode (nil from an unset ENV var, a number, a collection) raises
    # ConfigurationError rather than NoMethodError, and the previous mode stands.
    def enforcement=(value)
      mode = value.respond_to?(:to_sym) ? value.to_sym : value

      unless ENFORCEMENT_MODES.include?(mode)
        raise ConfigurationError,
              "config.enforcement = #{value.inspect} is not a mode. " \
              "Use :enforce (deny means 403 — the production posture) or " \
              ":report (log what WOULD be denied and allow it through, to seed " \
              "grants before cutting over). Report mode is for adoption only: " \
              "it never lifts the separation-of-duties veto and never opens the " \
              "management console."
      end

      warn_report_mode_in_production if mode == :report && production?
      @enforcement = mode
    end

    # True only in report mode. A predicate, so callers can't express "not
    # enforcing" — the modes are a closed set, not a boolean.
    def report_only? = @enforcement == :report

    def initialize
      @user_method = :current_user
      @actor_method = nil
      @sod_actions = []
      @sod_identity = :either
      @allow_sod_bypass = false
      @sod_bypass_permission = "bypass_sod"
      @allow_mutations_while_impersonating = false
      @excluded_controllers = [
        %r{\Arails/}, %r{\Aactive_storage/}, %r{\Aaction_mailbox/},
        %r{\Aturbo/}, %r{\Acurrent_scope/}
      ]
      @parent_controller = "::ApplicationController"
      @subject_class = "User"
      @audit = true
      @enforcement = :enforce
      @warn_on_nil_sod_record = false
      @permission_grid_groups = {
        "read"    => %w[index show],
        "create"  => %w[new create],
        "update"  => %w[edit update],
        "destroy" => %w[destroy]
      }
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

    # Report mode in production is DELIBERATELY allowed — surveying real traffic
    # is the most honest way to find out what to grant, and a staging run won't
    # show you the flows your actual users take. Refusing it here would break the
    # feature's best use case.
    #
    # But "we are not enforcing authorization" is not a state a production app
    # should be in silently, or for long. The failure mode is quiet: nothing
    # breaks, no one is refused, and the temporary survey becomes the permanent
    # posture because nothing ever reminded anyone. So it says so at boot, once,
    # where a deploy log will keep it.
    #
    # ponytail: a warn, not a raise. Unlike allow_mutations_while_impersonating
    # (which has an env-gate refusal) this has a legitimate production use and a
    # deliberate exit — the host is mid-migration, and the loud reminder is the
    # right amount of friction.
    def warn_report_mode_in_production
      message = "[CurrentScope] config.enforcement = :report in PRODUCTION — " \
                "authorization is NOT being enforced. Missing grants are logged " \
                "as access.would_deny and the request is ALLOWED THROUGH. This is " \
                "an adoption ramp, not a production posture: seed the grants the " \
                "ledger names, then set config.enforcement = :enforce."

      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      else
        # Boot order: an initializer can run before the logger exists. Say it
        # anyway — a warning nobody sees is the thing this method exists to
        # prevent.
        warn(message)
      end
    end

    def production?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
    end
  end
end
