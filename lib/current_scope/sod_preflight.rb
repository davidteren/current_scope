module CurrentScope
  # Finds, before traffic does, the separation-of-duties actions that are going
  # to raise CurrentScope::ConfigurationError: an action listed in
  # config.sod_actions reaching a model that defines no current_scope_initiator.
  #
  # The raise itself is correct and stays (a silently skipped veto is the hole
  # #73/#74 exist to prevent). What was wrong is WHEN a host learns about it —
  # per request, from real traffic, including in :report mode, which promises
  # that nothing changes for users. This answers the same question as soon as
  # the routes exist, where the fix is cheap. (#133)
  #
  # "As soon as the routes exist" is BOOT in an eager-loading environment
  # (production and staging — where a bake runs) and the first request in
  # development, whose route set is lazy. The engine initializer says why.
  #
  # ADVISORY AND PARTIAL BY CONSTRUCTION, for the reason #134 recorded: the
  # record a member action decides about comes from current_scope_record, an
  # instance method whose value exists only mid-request, so "which model does
  # invoices#approve gate?" is not statically knowable. What IS declared is
  # current_scope_model (#50) — the type a controller's collection actions deal
  # in. Under Rails' resource conventions that is the type its member actions
  # load too, which makes it a good signal and not a proof:
  #
  #   false negative — a controller declaring no current_scope_model is never
  #                    inspected, so its 500 still arrives with traffic. That
  #                    gap is why the report-mode ledger row exists as well
  #                    (Guard#diagnose_report_sod_initiator).
  #   false positive — a controller whose member action loads a DIFFERENT type
  #                    than its collection lists gets named against the wrong
  #                    model. Costs a look; it can never break an app.
  #
  # Both limits are stated in the output the operator reads, not in a guide they
  # will not open — the rule GrantDiagnosis.untargeted_caveat set.
  module SodPreflight
    # One scan's answer, carried as a value instead of left on the module.
    #
    # Every honesty rule this feature has needed — "an empty list is not an
    # all-clear", "a run that skipped checks under-reports", "a run that
    # inspected nothing proves nothing" — is a question about ONE scan. Holding
    # that on a singleton made the answers depend on call order, needed a
    # fail-closed special case for "never run", and made the rake task capture a
    # flag next to the call so 140 lines later it still meant the right run.
    # A value has none of those problems: you cannot ask a result you do not
    # have. (#133 review — cubic, ie-predictability, ie-architecture all landed
    # on this seam.)
    Result = Struct.new(:rows, :inspected, :in_scope, :skipped, keyword_init: true) do
      # Some check could not be completed, so the list under-reports.
      def degraded? = skipped.any?

      # The list cannot be read as an all-clear: either a check failed, or there
      # was nothing to read because no controller in scope declared a model.
      def blind? = degraded? || (inspected.zero? && in_scope.positive?)

      def any? = rows.any?
    end

    class << self
      # Scan the routed SoD actions and return a Result. PURE: it reads routes,
      # declarations and models, and returns; rendering and logging belong to the
      # callers (warn! for the log, `rails current_scope:report` for stdout), so
      # scanning twice cannot emit twice.
      #
      # Free for the default config: sod_actions is [] until a host opts in, and
      # nothing here touches a controller until it is not.
      def scan
        return Result.new(rows: [], inspected: 0, in_scope: 0, skipped: []) if
          CurrentScope.config.sod_actions.empty?

        reflection = CurrentScope::GatingReflection.new
        models = {}
        skipped = []
        inspected = 0
        in_scope = 0

        rows = sod_permissions.filter_map do |controller, permission|
          in_scope += 1
          model = models.fetch(controller) {
            models[controller] = declared_model_for(controller, reflection, skipped)
          }
          next if model.nil?

          inspected += 1
          next if defines_initiator?(model, skipped)

          [ permission, model ]
        end

        Result.new(rows: rows, inspected: inspected, in_scope: in_scope, skipped: skipped)
      rescue StandardError => e
        # An advisory must never be the thing that breaks a boot.
        #
        # NoMethodError re-raises, matching GrantDiagnosis: at THIS level it can
        # only be our own bug. Every call into host code — building the
        # controller, reading the hook, instantiating the model — is wrapped by
        # the two helpers below, which own those failures and never let them
        # reach here. So a NoMethodError that escapes to this line came from the
        # catalog walk or the loop, i.e. from us, and swallowing it would report
        # a gem bug as a host misconfiguration. The helpers deliberately do NOT
        # copy this re-raise: a hook reading `params` on a request-less
        # controller raises NoMethodError, and that is the single likeliest host
        # failure here — exactly what they must absorb. (The sibling can rescue
        # narrowly throughout because it calls no host code at all.)
        raise if e.instance_of?(NoMethodError)

        # A whole run that died is a run that proves nothing: report it as one
        # skipped check so the Result reads blind rather than clean.
        Result.new(rows: [], inspected: 0, in_scope: 0, skipped: [ [ "the scan itself", e ] ])
      end

      # One message listing every action that will raise, plus the coverage
      # behind an empty list. Log-only.
      def warn!(result = scan)
        skips = skip_summary(result)
        Rails.logger&.warn(skips) if skips

        if result.rows.empty?
          return unless result.blind?

          return Rails.logger&.warn(blind_message(result))
        end

        listed = result.rows.map { |permission, model|
          "  #{permission} — #{model.name} defines no #{Resolver::INITIATOR_METHOD}"
        }

        Rails.logger&.warn(
          "[CurrentScope] separation-of-duties preflight: #{result.rows.size} routed action(s) " \
          "will raise CurrentScope::ConfigurationError on the first request that reaches them — " \
          "in config.enforcement = :report exactly as in :enforce.\n" \
          "#{listed.join("\n")}\n" \
          "#{fix_line}\n#{caveat}"
        )
      end

      # The limits of the answer, in the output rather than in a guide. Shared by
      # the boot warning and `rails current_scope:report` so the two cannot drift
      # into different versions of the same hedge (the drift #134 fixed for the
      # untargeted-grant caveat).
      # LINE-BROKEN on purpose. All five limits are real and two were added by
      # review, so the answer to "this is a wall" is never fewer limits — it is
      # structure. An unread caveat protects nobody, and this one is the only
      # thing standing between a fallible list and a host deleting a four-eyes
      # control. Its sibling GrantDiagnosis.untargeted_caveat is short for the
      # same reason. (#133 review)
      def caveat
        [
          "This list is PARTIAL — a lead, not a verdict. Confirm against the model before " \
          "you change config.sod_actions.",
          "  Silent when: the controller declares no current_scope_model (ABSENT is not " \
          "cleared), or the model cannot be instantiated right now (no database connection " \
          "yet, a custom initialize).",
          "  Names the wrong thing when: the declared type is what the COLLECTION lists and " \
          "a member action loads a different one; or current_scope_model branches on " \
          "action_name, which is read here with no action in hand.",
          "  Cannot happen at all: a finding against an action that turns out to be a " \
          "COLLECTION action — the veto never reaches those."
        ].join("\n")
      end

      # The two remedies are NOT coequal here, and this message must not present
      # them as if they were. Defining the hook restores a control; removing the
      # action from config.sod_actions DELETES a fraud control. On the raise in
      # Resolver#sod_decision the cause is proven, so offering both plainly is
      # right. This list can be wrong — it reads a declaration, not the record —
      # so leading with "or just turn the veto off" invites a host to disable
      # four-eyes on a false accusation. Lead with the hook; qualify the rest.
      #
      # PUBLIC beside #caveat, and for the identical reason: `rails
      # current_scope:report` renders the SAME finding, so a private copy here
      # guaranteed the correction reached one surface and not the other. It did
      # exactly that for one commit. (#133 review)
      def fix_line
        "Fix: define #{Resolver::INITIATOR_METHOD} on each model listed (return nil to exempt a " \
        "record). Only if the action was never meant to be four-eyes gated should you remove it " \
        "from config.sod_actions — that removes the control rather than wiring it, so confirm " \
        "the finding first."
      end

      # One line per run, naming the count and the distinct causes — never one
      # line per controller. The failure this class expects most is a
      # current_scope_model hook that reads request-scoped state, and that one
      # fails for EVERY affected controller on every routes load; a per-row line
      # would flood exactly the host it is trying to help. Every sibling
      # diagnostic in this engine throttles for the same reason
      # (Guard.warn_ledger_failure_once, Event.warn_missing_events_table_once,
      # the cross-controller nudge's once-per-site set).
      #
      # Broken controllers are called out separately because their fix differs:
      # the controller does not LOAD, which the gate will hit too. Derived from
      # the error class, not carried as a flag — a NameError can only arrive from
      # inside a controller's own body, because a missing controller CONSTANT
      # became MissingController and returned nil earlier. That is the
      # distinction GatingReflection#controller_class exists to keep.
      #
      # Returns the string (nil when nothing was skipped) rather than logging, so
      # `rails current_scope:report` can render the same facts to stdout — the
      # operator reading a terminal must not be told to go and find a log.
      def skip_summary(result)
        return nil if result.skipped.empty?

        broken = result.skipped.select { |_s, error| error.is_a?(NameError) }
        detail = result.skipped.map { |subject, error| "#{subject} (#{error.class})" }.uniq.join(", ")

        message = +"[CurrentScope] SodPreflight skipped #{result.skipped.size} check(s), so its " \
                   "list is INCOMPLETE — absence below is not an all-clear: #{detail}."
        if broken.any?
          message << " #{broken.size} of those did not LOAD (#{broken.map(&:first).uniq.join(', ')}) " \
                     "— that is a broken controller, not a missing declaration, and the gate will " \
                     "fail there too."
        end
        message
      end

      private

      def blind_message(result)
        reason =
          if result.inspected.zero? && result.in_scope.positive?
            "it inspected NONE of the #{result.in_scope} routed SoD action(s) — none of those " \
            "controllers declares current_scope_model, so there was nothing to read"
          else
            "it was not able to look properly (some checks were skipped; see the lines above)"
          end

        "[CurrentScope] separation-of-duties preflight found nothing, and #{reason}. Do NOT " \
        "read that as an all-clear. Re-run `rails current_scope:report` once the app is fully " \
        "up.\n#{caveat}"
      end

      # [[controller_path, permission], ...] for every ROUTED SoD action.
      #
      # routed?, not include?: the catalog also injects the break-glass key, and
      # an injected key gates no request, so it can never raise. (The bypass
      # permission is barred from sod_actions by Configuration#validate! anyway;
      # asking the catalog costs one set lookup and removes the question.)
      def sod_permissions
        actions = CurrentScope.config.sod_actions
        catalog = CurrentScope.catalog

        catalog.grouped.flat_map do |controller, controller_actions|
          (controller_actions & actions).filter_map do |action|
            key = "#{controller}##{action}"
            [ controller, key ] if catalog.routed?(key)
          end
        end
      end

      # The type this controller declared, or nil when it declared none, nothing
      # is routed there, or asking failed. Mirrors Guard#resolve_current_scope_model
      # — same private hook, same respond_to?(…, true) discovery — because a
      # second spelling of "what did the host declare?" is a second spelling that
      # drifts.
      def declared_model_for(controller_path, reflection, skipped)
        klass = reflection.controller_class(controller_path)
        return nil if klass.nil?

        instance = klass.new
        return nil unless instance.respond_to?(:current_scope_model, true)

        model = instance.send(:current_scope_model)
        # ASK the resolver for the shape rule rather than re-spelling its three
        # terms here: a concrete ActiveRecord class. Anything else cannot be the
        # record an SoD veto measures, so there is nothing to prove and this
        # stays silent — a mis-declared type is :model_invalid's job, not this
        # one's. (An inline copy is the #74 re-derivation defect, and this file
        # already avoids it for the initiator check.)
        return nil unless CurrentScope.resolver.collection_type?(model)

        model
      rescue StandardError => e
        # HOST CODE RUNS HERE — an instance method, on a controller built outside
        # a request. A hook that reads params is the likeliest failure and must
        # be absorbed, never raised: this is an advisory.
        #
        # A NameError is called out separately because GatingReflection was made
        # public precisely to preserve Rails' triage — a missing controller
        # constant became MissingController (already nil above), so a NameError
        # arriving HERE came from inside the controller's own body. Folding that
        # into the same "could not inspect" line as a params-reading hook would
        # report a broken controller exactly like a fine one, which is the
        # distinction that reflection exists to keep. (#133 review)
        skipped << [ controller_path, e ]
        nil
      end

      # ASKS an instance the same question the resolver asks the record, rather
      # than re-deriving it as method_defined?: respond_to?(…, true) also honours
      # protected/private definitions and respond_to_missing?, and re-deriving a
      # condition another component owns is the defect this codebase keeps paying
      # for (#74).
      #
      # Model.new issues no QUERY, but it is not connection-free: the first
      # instantiation loads the schema to build the attribute set. On a boot with
      # no reachable database (asset precompile, a container started before its
      # DB) that raises, every model reads as compliant, and the list is empty
      # for a reason the operator cannot see — which is why the caveat names it
      # and #degraded? reports it.
      def defines_initiator?(model, skipped)
        model.new.respond_to?(Resolver::INITIATOR_METHOD, true)
      rescue StandardError => e
        # Could not tell (a custom initialize, an after_initialize that needs a
        # request) ⇒ say nothing. Prove or stay silent.
        skipped << [ model.name || model.inspect, e ]
        true
      end
    end
  end
end
