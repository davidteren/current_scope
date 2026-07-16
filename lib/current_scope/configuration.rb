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
    # See the validating writer below — an unknown value must not silently
    # narrow the veto.
    attr_reader :sod_identity

    SOD_IDENTITY_MODES = %i[either subject].freeze

    # Validating writer, same contract as enforcement=: the resolver compares
    # `== :either`, so a typo (`:both`, `:actor`) would otherwise silently
    # behave as :subject — narrowing the fraud control with no signal. Raise at
    # assignment naming the closed set; the previous mode stands.
    def sod_identity=(value)
      mode = value.respond_to?(:to_sym) ? value.to_sym : value

      unless SOD_IDENTITY_MODES.include?(mode)
        raise ConfigurationError,
              "config.sod_identity = #{value.inspect} is not a mode. " \
              "Use :either (default — the veto binds the effective subject AND, " \
              "while impersonating, the real actor, so impersonation can never " \
              "approve the actor's own record) or :subject (weigh only the " \
              "effective subject)."
      end

      @sod_identity = mode
    end

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

    # Env var that opts a PRODUCTION deploy into impersonated writes. The VALUE
    # is what counts: a truthy value ("1", "true", "yes"…) lifts the production
    # refusal; unset, "", "false", "0", "off" all mean "not opted in" — an
    # operator writing `…=false` in a deploy manifest gets what they said, not
    # the opposite. development/test/staging never consult it.
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
    # See the validating writer below — a misspelled :strict must not silently
    # downgrade an audit-mandatory host to best-effort.
    attr_reader :audit

    AUDIT_MODES = [ false, true, :strict ].freeze

    # Validating writer, same contract as enforcement=: because record! checks
    # `== :strict`, a typo (`:strixt`) is truthy and would silently behave as
    # plain true — the host believes unaudited mutations roll back while they
    # commit. Raise at assignment naming the closed set; the previous mode
    # stands.
    def audit=(value)
      # ENV can only carry strings, and two of the three modes are booleans —
      # normalize the boolean spellings before symbolizing ("strict" → :strict).
      mode = case value
      when "true" then true
      when "false" then false
      else value.respond_to?(:to_sym) ? value.to_sym : value
      end

      unless AUDIT_MODES.include?(mode)
        raise ConfigurationError,
              "config.audit = #{value.inspect} is not a mode. " \
              "Use false (record! is a silent no-op — no ledger), " \
              "true (append a row per event, degrade gracefully if the events " \
              "table is missing), or :strict (a missing events table RAISES so " \
              "a mutation-wrapping transaction rolls back rather than " \
              "committing an unaudited grant)."
      end

      @audit = mode
    end

    # --- Dev diagnostics (#41) ----------------------------------------------
    #
    # Four failure modes this engine has that are SILENT and silent in the bad
    # direction: the thing that went wrong looks exactly like the thing going
    # right. Each is a cheap log line in dev/test and costs nothing in prod.
    #
    # All four default ON in development and test, OFF in production — and off
    # entirely when Rails isn't loaded. The default is the point: a diagnostic
    # nobody knows about is a diagnostic nobody benefits from, and these
    # protect against mistakes you make while WRITING the app, which is exactly
    # when dev/test is where you are. A host can force any of them either way.
    #
    # Every one is LOG-ONLY. No decision, exception, header, or audit row
    # changes because of them, in any environment.

    # The gate logs a nudge when an SoD action is gated with no record and the
    # request is ALLOWED — i.e. the veto was skipped because current_scope_record
    # returned nil (or was never declared) on a member action. The gem's #1
    # foot-gun: the veto silently not running looks identical to the veto passing.
    #
    # Emitted from the Guard seam (not the shared resolver), so it never fires on
    # advisory allowed_to?/scope_for calls.
    attr_accessor :warn_on_nil_sod_record

    # The gate logs a nudge when a request is DENIED :no_grant, the controller
    # declared no current_scope_record hook at all, and the subject holds a
    # scoped grant that WOULD have applied had the hook returned the record.
    #
    # That combination is a controller with member actions that forgot the hook.
    # It fails closed — correctly — but the 403 is indistinguishable from "you
    # were never granted this", so the person debugging it goes looking at their
    # grants, which are fine, instead of at their controller, which isn't.
    attr_accessor :warn_on_inert_scoped_grant

    # CurrentScope.permission_key logs a nudge when short-form derivation
    # (`allowed_to?(:show, report)`) resolves to a DIFFERENT key than the one the
    # current controller's gate enforces — the documented namespaced/custom-named
    # controller foot-gun. The view then shows a link that 403s, or hides one that
    # would have worked: the gate and the view disagree, silently, and the symptom
    # shows up nowhere near the cause.
    attr_accessor :warn_on_cross_controller_derivation

    # The gate logs a nudge when a request is DENIED :model_undeclared — a
    # declared collection action (current_scope_record returned nil) whose
    # controller names no current_scope_model, while the subject holds a scoped
    # grant ticking the key. The record-less branch had no type to bind that
    # grant to, so it failed closed (#50) — correctly, but the 403 looks like
    # "never granted" while the fix is one line in the controller.
    attr_accessor :warn_on_undeclared_collection_model

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

    # :raise | :warn — what the opt-in GatingTripwire mixin (A4) does when it
    # catches an action that completed without running the gate.
    #
    #   :raise — fail loudly. Default in development/test: an ungated action is
    #            a hole you want CI to go red on, not one to discover in an audit.
    #   :warn  — log once per controller#action and let the response through, so
    #            a real app can inventory its ungated surface without 500ing.
    #
    # A closed two-mode set, like enforcement — not a boolean, and no :off:
    # not including the mixin is off.
    attr_reader :gating_tripwire

    GATING_TRIPWIRE_MODES = %i[raise warn].freeze

    # Validating writer, same contract as enforcement=: an unknown value raises
    # at assignment naming both modes, and the previous mode stands. Accepts a
    # String so ENV["..."] works.
    def gating_tripwire=(value)
      mode = value.respond_to?(:to_sym) ? value.to_sym : value

      unless GATING_TRIPWIRE_MODES.include?(mode)
        raise ConfigurationError,
              "config.gating_tripwire = #{value.inspect} is not a mode. " \
              "Use :raise (an ungated action fails loudly — the dev/test posture) " \
              "or :warn (log it once per controller#action and let the response " \
              "through, to inventory an app's ungated surface). There is no :off — " \
              "not including CurrentScope::GatingTripwire is off."
      end

      @gating_tripwire = mode
    end

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
      # Reuses diagnostics_default_on? for its env split and bare-Ruby safety
      # ONLY — do NOT carry over the diagnostics flags' emit/silence reading.
      # There, false means stay quiet; here, false means :warn, which EMITS.
      # The inversion is deliberate: the tripwire mixin is opt-in, so a
      # production host that included it is asking for the ungated inventory —
      # the env decides only whether a hit 500s (dev/test) or logs (elsewhere).
      @gating_tripwire = diagnostics_default_on? ? :raise : :warn
      @warn_on_nil_sod_record = diagnostics_default_on?
      @warn_on_inert_scoped_grant = diagnostics_default_on?
      @warn_on_cross_controller_derivation = diagnostics_default_on?
      @warn_on_undeclared_collection_model = diagnostics_default_on?
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
      if value && production? && !prod_mutations_opt_in?
        raise ConfigurationError,
              "config.allow_mutations_while_impersonating = true is refused in " \
              "production: letting a real actor write as the subject they " \
              "impersonate is a privilege-escalation and audit-integrity risk. " \
              "Keep it false so impersonated sessions stay read-only in " \
              "production, or — only if writes under act-as are genuinely " \
              "required (e.g. a live public showcase) — set ENV[\"#{PROD_MUTATIONS_ENV}\"] " \
              "to a truthy value (\"1\"/\"true\") to opt in explicitly; \"false\", " \
              "\"0\", and empty mean not opted in. development, test, and staging " \
              "are unaffected."
      end
      @allow_mutations_while_impersonating = value
    end

    private

    # The env var's VALUE means what it says — presence alone is not consent.
    # ActiveModel's boolean cast maps "false"/"0"/"f"/"off" to false and "" to
    # nil; anything else present is truthy. Only reached when production? is
    # already true, so Rails (and ActiveModel) are loaded — a bare-Ruby
    # Configuration.new never gets here.
    def prod_mutations_opt_in?
      !!ActiveModel::Type::Boolean.new.cast(ENV[PROD_MUTATIONS_ENV])
    end

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

    # Diagnostics are on where you are while writing the app, off where they'd
    # be noise on someone else's dime. `local?` is Rails' own name for
    # "development or test", so a host with a staging env that reports itself as
    # neither gets prod behaviour — the conservative side for a log line.
    #
    # Mirrors the production? guard below: a bare-Ruby Configuration.new with no
    # Rails must not raise, and gets false (no logger to warn to anyway).
    def diagnostics_default_on?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.local?
    end

    def production?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
    end
  end
end
