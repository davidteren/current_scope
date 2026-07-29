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
    class << self
      # [[permission, model_class], ...] — one row per routed SoD action whose
      # declared model cannot answer current_scope_initiator. Empty, and free,
      # for the default config: sod_actions is [] until a host opts in, and
      # nothing here touches a controller until it is not.
      def findings
        @degraded = false
        @skipped = []
        return [] if CurrentScope.config.sod_actions.empty?

        reflection = CurrentScope::GatingReflection.new
        models = {}

        rows = sod_permissions.filter_map do |controller, permission|
          model = models.fetch(controller) { models[controller] = declared_model_for(controller, reflection) }
          next if model.nil?
          next if defines_initiator?(model)

          [ permission, model ]
        end
        report_skipped
        rows
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

        log_degrade(e)
        []
      end

      # True when the last #findings run could not complete some check and
      # therefore under-reports. Read by `rails current_scope:report` so an
      # operator is never shown an empty section that looks like an all-clear
      # when it is really a broken check — the vacuous-all-clear rule the
      # ungated task already follows.
      def degraded? = !!@degraded

      # One message listing every action that will raise. Log-only.
      def warn!
        rows = findings
        # Silence is only honest when the run was CLEAN. A container that boots
        # before its database is reachable fails every model check, finds
        # nothing, and would otherwise say nothing at all — the vacuous
        # all-clear, on the one surface a host reads at deploy time. The report
        # task already refuses that; so does this. (#133 review)
        return if rows.empty? && !degraded?
        return Rails.logger&.warn(blind_message) if rows.empty?

        listed = rows.map { |permission, model|
          "  #{permission} — #{model.name} defines no #{Resolver::INITIATOR_METHOD}"
        }

        Rails.logger&.warn(
          "[CurrentScope] separation-of-duties preflight: #{rows.size} routed action(s) will " \
          "raise CurrentScope::ConfigurationError on the first request that reaches them — in " \
          "config.enforcement = :report exactly as in :enforce.\n" \
          "#{listed.join("\n")}\n" \
          "#{fix_line}\n#{caveat}"
        )
      end

      # The limits of the answer, in the output rather than in a guide. Shared by
      # the boot warning and `rails current_scope:report` so the two cannot drift
      # into different versions of the same hedge (the drift #134 fixed for the
      # untargeted-grant caveat).
      def caveat
        "This list is PARTIAL — read it as a lead, not a verdict. It can be silent when it " \
        "should not be: a controller that declares no current_scope_model is never inspected " \
        "(ABSENT here is not cleared), and a model that cannot be instantiated right now (no " \
        "database connection yet, a custom initialize) is passed over. It can also name the " \
        "wrong thing: the declared type is what the COLLECTION lists, so a member action " \
        "loading a different type is named against the wrong model; the declaration is read " \
        "with no action in hand, so a current_scope_model that branches on action_name answers " \
        "from its nil-action branch; and an action that turns out to be a COLLECTION action at " \
        "runtime can never reach the veto at all, so a finding against one is a false alarm. " \
        "Confirm against the model before you change config.sod_actions."
      end

      private

      # The two remedies are NOT coequal here, and this message must not present
      # them as if they were. Defining the hook restores a control; removing the
      # action from config.sod_actions DELETES a fraud control. On the raise in
      # Resolver#sod_decision the cause is proven, so offering both plainly is
      # right. This list can be wrong — it reads a declaration, not the record —
      # so leading with "or just turn the veto off" invites a host to disable
      # four-eyes on a false accusation. Lead with the hook; qualify the rest.
      # (#133 review)
      def fix_line
        "Fix: define #{Resolver::INITIATOR_METHOD} on each model listed (return nil to exempt a " \
        "record). Only if the action was never meant to be four-eyes gated should you remove it " \
        "from config.sod_actions — that removes the control rather than wiring it, so confirm " \
        "the finding first."
      end

      def blind_message
        "[CurrentScope] separation-of-duties preflight COULD NOT COMPLETE — it found nothing, " \
        "and it was not able to look properly, so do NOT read that as an all-clear. The skipped " \
        "checks are logged above. Re-run `rails current_scope:report` once the app is fully " \
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
      def declared_model_for(controller_path, reflection)
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
        skip(controller_path, e, broken_controller: e.is_a?(NameError))
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
      def defines_initiator?(model)
        model.new.respond_to?(Resolver::INITIATOR_METHOD, true)
      rescue StandardError => e
        # Could not tell (a custom initialize, an after_initialize that needs a
        # request) ⇒ say nothing. Prove or stay silent.
        skip(model.name || model.inspect, e)
        true
      end

      # Record one skipped check. COLLECTED, not logged on the spot: the failure
      # this class expects most is a current_scope_model hook that reads
      # request-scoped state, and that one fails for EVERY affected controller
      # on every routes load — a per-controller line would be a flood on exactly
      # the host it is trying to help, and every sibling diagnostic in this
      # engine throttles for that reason (Guard.warn_ledger_failure_once,
      # Event.warn_missing_events_table_once, the cross-controller nudge's
      # once-per-site set). One aggregated line per run instead. (#133 review)
      def skip(subject, error, broken_controller: false)
        @degraded = true
        (@skipped ||= []) << [ subject, error, broken_controller ]
      end

      # One line per run, naming the count and the distinct causes. Broken
      # controllers are listed separately because their fix is different: the
      # controller does not load at all, which the gate will hit too.
      def report_skipped
        return if @skipped.nil? || @skipped.empty?

        broken = @skipped.select { |_s, _e, is_broken| is_broken }
        detail = @skipped.map { |subject, error, _b| "#{subject} (#{error.class})" }.uniq.join(", ")

        message = +"[CurrentScope] SodPreflight skipped #{@skipped.size} check(s), so its list " \
                   "is INCOMPLETE — absence below is not an all-clear: #{detail}."
        if broken.any?
          message << " #{broken.size} of those did not LOAD (#{broken.map(&:first).join(', ')}) — " \
                     "that is a broken controller, not a missing declaration, and the gate will " \
                     "fail there too."
        end
        Rails.logger&.warn(message)
      end

      # The top-level rescue's degrade: the whole run died, not one check.
      def log_degrade(error)
        @degraded = true
        Rails.logger&.warn(
          "[CurrentScope] SodPreflight could not complete a check " \
          "(#{error.class}: #{error.message}); reporting no finding for it."
        )
      end
    end
  end
end
