module CurrentScope
  # Judges a scoped grant. Two methods, two certainties:
  #
  #   verdict_for      PROVEN — the grant cannot match anything, for any type.
  #   type_untargeted? ADVISORY — suggestive only; the host's runtime hooks
  #                    decide what a controller resolves to, so this can be
  #                    wrong and says so where the operator reads it.
  #
  # Neither is #90's "inert" (the RECORD is gone; different fix).
  # Design rationale: docs/plans/2026-07-28-032-feat-unresolvable-grant-guardrail-plan.md
  module GrantDiagnosis
    class << self
      # Proven, or nil. Never guesses.
      def verdict_for(grant)
        return nil if orphaned?(grant)

        role = grant.role
        return nil if role.nil? || role.full_access?

        keys = persisted_keys(role)
        # Checked BEFORE the catalog guard: a role with nothing ticked can never
        # match whatever the catalog says, so deferring to "no verdict" here
        # would downgrade a proven finding to an advisory.
        return :no_permissions if keys.empty?

        # An empty catalog means routes are not derived yet, not that every key
        # is dead. Only the unrouted claim depends on it.
        return nil if CurrentScope.catalog.keys.empty?
        return :unrouted_permissions if keys.none? { |key| live?(key, resource_class(grant)) }

        nil
      rescue NameError, ActiveRecord::ActiveRecordError => e
        raise if e.instance_of?(NoMethodError)

        log_degrade(e)
        nil
      end

      # `verdict:` lets a caller that already has it skip the recompute (three
      # role_permissions plucks per grant otherwise).
      def type_untargeted?(grant, verdict: :__unset)
        verdict = verdict_for(grant) if verdict == :__unset
        return false unless verdict.nil?
        return false if orphaned?(grant)

        role = grant.role
        return false if role.nil? || role.full_access?

        return false unless ensure_models_loaded!

        klass = resource_class(grant)
        return false if klass.nil? # unresolvable class is #90's inert, not ours

        keys = persisted_keys(role)
        return false if keys.any? { |key| routed?(key) && targets_any_route_key?(key, klass) }

        # #108: a grant on a PARENT legitimately reaches its children, so stay
        # silent when any declared chain reaches this class.
        !reachable_through_declared_chain?(klass, keys)
      rescue NameError, ActiveRecord::ActiveRecordError => e
        raise if e.instance_of?(NoMethodError)

        log_degrade(e)
        false
      end

      # The advisory's caveat, centralised for the same reason the proven wording
      # is: the console and the CLI had drifted into two versions of it.
      def untargeted_caveat
        "This is NOT a verdict. Only your current_scope_record hooks decide which " \
        "records a controller resolves to, and that is not knowable statically. A " \
        "controller serving this type under a different name is a false alarm here. " \
        "Check the hook before removing anything."
      end

      # One wording, so the task and the view cannot drift.
      def verdict_label(verdict)
        case verdict
        when :no_permissions       then "role ticks no permissions"
        when :unrouted_permissions then "role ticks only unrouted keys"
        end
      end

      def verdict_fix(verdict)
        case verdict
        when :no_permissions
          "Tick at least one permission on this role, or remove the grant."
        when :unrouted_permissions
          "Every key on this role is absent from the route-derived catalog, so " \
          "nothing can ever gate them. Re-tick the role against current routes."
        end
      end

      private

      # #90's state, not ours — two badges naming different remedies on one
      # grant is the confusion this feature exists to end.
      # Never the STAGED keys Role#permission_keys returns after a failed save.
      def persisted_keys(role)
        role.role_permissions.pluck(:permission_key)
      end

      def log_degrade(error)
        Rails.logger&.warn(
          "[CurrentScope] GrantDiagnosis could not judge a scoped grant " \
          "(#{error.class}: #{error.message}); reporting no finding for it."
        )
      end

      def orphaned?(grant)
        grant.respond_to?(:orphaned_resource?) && grant.orphaned_resource?
      end

      # A polymorphic grant stores the STI BASE class, but the routed controller
      # is named after the SUBCLASS — so a grant on an Invoice (stored
      # "Document") whose role ticks "invoices#show" WORKS and must not be
      # flagged. Check every route key in the hierarchy.
      def targets_any_route_key?(key, klass)
        ([ klass ] + klass.descendants).any? do |candidate|
          targets_route_key?(key, candidate.model_name.route_key)
        end
      rescue StandardError
        true # unknown hierarchy: stay silent, never flag on a guess
      end

      # declared_names fills as model classes LOAD. With eager loading off (the
      # default in development, where this task is run) the chain lookup is
      # blind and would flag the very #108 grants it exists to protect — and
      # order-dependently, since an earlier row could load the model. Force the
      # load once.
      # Returns false when the registry may be incomplete, so the caller stays
      # silent rather than negating a partial answer into an advisory. Latches
      # only on success, so a transient failure can retry.
      def ensure_models_loaded!
        return true if @models_loaded

        Rails.application.eager_load! unless Rails.application.config.eager_load
        @models_loaded = true
      rescue StandardError => e
        log_degrade(e)
        false
      end

      # Walks the same declared reflections the resolver walks, so the two
      # cannot disagree about what a chain reaches.
      def reachable_through_declared_chain?(klass, keys)
        CurrentScope::ParentChain.declared_names.any? do |name|
          child = name.safe_constantize
          next false if child.nil?
          next false unless keys.any? { |key| routed?(key) && targets_any_route_key?(key, child) }

          chain_reaches?(child, klass)
        end
      end

      def chain_reaches?(child, klass)
        current = child
        CurrentScope::ParentChain::MAX_PARENT_DEPTH.times do
          reflection = CurrentScope::ParentChain.reflection_for(current)
          return false if reflection.nil?
          return true if reflection.klass.base_class == klass.base_class

          current = reflection.klass
        end
        false
      end

      def resource_class(grant)
        klass = grant.resource_type&.safe_constantize
        klass.respond_to?(:model_name) ? klass : nil
      end

      # Can this key ever open anything for THIS grant? Routed keys can. So can
      # the catalog's injected break-glass key — but only on the rows it was
      # injected onto, so the exemption is row-local: a bypass key for another
      # type cannot lift anything here.
      def live?(key, klass)
        return true if CurrentScope.catalog.routed?(key)

        return false unless injected?(key)

        # A FULL sod_bypass_permission ("claims#bypass_sod") is the key the
        # resolver checks for every record, so it is live on any grant and the
        # row-local heuristic must not apply. Only a bare action is per-row.
        configured = CurrentScope.config.sod_bypass_permission.to_s
        return key == configured if configured.include?("#")

        !klass.nil? && targets_any_route_key?(key, klass)
      end

      def injected?(key)
        CurrentScope.catalog.include?(key) && !CurrentScope.catalog.routed?(key)
      end

      def routed?(key)
        CurrentScope.catalog.routed?(key)
      end

      # Wider than CurrentScope.permission_key's comparison: a controller segment
      # CONTAINING the route key counts, and both the namespaced and collapsed
      # forms are tried. Biased toward false negatives on purpose. Pins:
      # test/grant_diagnosis_test.rb (nested_reports, namespaced).
      def targets_route_key?(key, route_key)
        controller = key.split("#").first.to_s
        # BOTH forms: a namespaced model keeps its namespace in the route key
        # (Billing::Invoice -> "billing_invoices") while the controller path
        # splits it ("billing/invoices"), so comparing only the last segment
        # falsely flags the conventional Rails layout.
        [ controller.tr("/", "_"), controller.split("/").last.to_s ].any? do |segment|
          segment == route_key ||
            segment.end_with?("_#{route_key}") || segment.start_with?("#{route_key}_")
        end
      end
    end
  end
end
