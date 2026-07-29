module CurrentScope
  # Finds, before traffic does, the separation-of-duties actions that are going
  # to raise CurrentScope::ConfigurationError: an action listed in
  # config.sod_actions reaching a model that defines no current_scope_initiator.
  #
  # The raise itself is correct and stays (a silently skipped veto is the hole
  # #73/#74 exist to prevent). What was wrong is WHEN a host learns about it —
  # per request, from real traffic, including in :report mode, which promises
  # that nothing changes for users. This answers the same question at boot,
  # where the fix is cheap. (#133)
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
        return [] if CurrentScope.config.sod_actions.empty?

        reflection = CurrentScope::GatingReflection.new
        models = {}

        sod_permissions.filter_map do |controller, permission|
          model = models.fetch(controller) { models[controller] = declared_model_for(controller, reflection) }
          next if model.nil?
          next if defines_initiator?(model)

          [ permission, model ]
        end
      rescue StandardError => e
        # An advisory must never be the thing that breaks a boot.
        log_degrade(e)
        []
      end

      # One message at boot listing every action that will raise. Log-only.
      def warn!
        rows = findings
        return if rows.empty?

        listed = rows.map { |permission, model|
          "  #{permission} — #{model.name} defines no #{Resolver::INITIATOR_METHOD}"
        }

        Rails.logger&.warn(
          "[CurrentScope] separation-of-duties preflight: #{rows.size} routed action(s) will " \
          "raise CurrentScope::ConfigurationError on the first request that reaches them — in " \
          "config.enforcement = :report exactly as in :enforce.\n" \
          "#{listed.join("\n")}\n" \
          "Fix: define #{Resolver::INITIATOR_METHOD} on each model listed (return nil to exempt " \
          "a record), or remove the action from config.sod_actions.\n#{caveat}"
        )
      end

      # The limits of the answer, in the output rather than in a guide. Shared by
      # the boot warning and `rails current_scope:report` so the two cannot drift
      # into different versions of the same hedge (the drift #134 fixed for the
      # untargeted-grant caveat).
      def caveat
        "This list is PARTIAL. Only controllers that declare current_scope_model are " \
        "inspected, so an action on a controller without that declaration is ABSENT " \
        "here rather than cleared. And the declared type names what the COLLECTION " \
        "lists, so a member action loading a different type is named against the " \
        "wrong model. Read it as a lead, not a verdict."
      end

      private

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
        # The same shape the resolver's record-less branch requires of a declared
        # type (Resolver#collection_type?): a concrete ActiveRecord class.
        # Anything else cannot be the record an SoD veto measures, so there is
        # nothing to prove and this stays silent — a mis-declared type is
        # :model_invalid's job, not this one's.
        return nil unless model.is_a?(Class) && model < ActiveRecord::Base && !model.abstract_class?

        model
      rescue StandardError => e
        # HOST CODE RUNS HERE — an instance method, on a controller built outside
        # a request. A hook that reads params, or a broken controller body whose
        # NameError GatingReflection deliberately lets propagate, is a coverage
        # gap for this advisory and never a boot failure.
        log_degrade(e)
        nil
      end

      # ASKS an instance the same question the resolver asks the record, rather
      # than re-deriving it as method_defined?: respond_to?(…, true) also honours
      # protected/private definitions and respond_to_missing?, and re-deriving a
      # condition another component owns is the defect this codebase keeps paying
      # for (#74). Model.new touches no database.
      def defines_initiator?(model)
        model.new.respond_to?(Resolver::INITIATOR_METHOD, true)
      rescue StandardError => e
        # Could not tell (a custom initialize, an after_initialize that needs a
        # request) ⇒ say nothing. Prove or stay silent.
        log_degrade(e)
        true
      end

      def log_degrade(error)
        Rails.logger&.warn(
          "[CurrentScope] SodPreflight could not complete a check " \
          "(#{error.class}: #{error.message}); reporting no finding for it."
        )
      end
    end
  end
end
