module CurrentScope
  # The ONE place that judges a scoped grant (#134). It answers two different
  # questions and returns them separately ON PURPOSE, because they carry
  # different amounts of certainty and a caller must not be able to render one
  # as the other:
  #
  #   verdict_for(grant)   PROVEN — this grant cannot match anything, for any
  #                        type, whatever the host's hooks do.
  #   type_untargeted?     ADVISORY — no ticked key names a controller whose
  #                        route key matches this grant's type. Suggestive, NOT
  #                        conclusive; only the host's current_scope_record
  #                        hooks can settle it.
  #
  # WHY THE SPLIT, when #134 asked for one verdict: the verdict it asked for
  # cannot be proven. `current_scope_model` and `current_scope_record` are
  # INSTANCE methods whose values only exist at runtime, so "which controllers
  # resolve to type X" is not statically knowable. The obvious route-key
  # heuristic produces false positives in this repo's own dummy app —
  # `nested_reports#index` and `external_id_reports#show` both gate Report
  # records and neither route key equals "reports". Reporting one of those as
  # dead would tell an operator to remove a working grant.
  #
  # That is why the advisory is labelled rather than promoted: this codebase's
  # standing rule is that a diagnostic which cries wolf is worse than none
  # (`lib/current_scope.rb`), that a claim is made only when proven
  # (GatingReflection), and that a diagnostic which overstates is how a
  # diagnostic starts being ignored (`guard.rb`, warn_on_inert_scoped_grant).
  #
  # NOT the same as #90's "inert". That means the grant's RECORD is gone and the
  # fix is to remove the grant. These mean the grant's ROLE reaches nothing, and
  # the fix is to tick a key (or grant on a different record). Three states an
  # operator must tell apart: missing, inert, cannot-match.
  module GrantDiagnosis
    class << self
      # Proven, or nil. Never guesses.
      def verdict_for(grant)
        return nil if orphaned?(grant)

        role = grant.role
        return nil if role.nil? || role.full_access?

        # An empty catalog means routes have not been derived yet, NOT that every
        # key is dead. Without this, one badly-timed read reports every grant in
        # the app as unresolvable — the mass false positive this whole design is
        # built to avoid.
        return nil if CurrentScope.catalog.keys.empty?

        keys = persisted_keys(role)
        return :no_permissions if keys.empty?
        return :unrouted_permissions if keys.none? { |key| routed?(key) }

        nil
      rescue NameError, ActiveRecord::ActiveRecordError => e
        # Narrow on purpose. A blanket rescue would turn a real
        # ConfigurationError into a "healthy" nil — a diagnostic that BROKE
        # reading as a diagnostic that found nothing. Log so the silence is
        # explainable.
        log_degrade(e)
        nil
      end

      # Advisory. Silent whenever verdict_for speaks — a weaker second sentence
      # about the same grant is noise, and the stronger one already names the
      # fix.
      # `verdict:` lets a caller that already computed the verdict pass it in.
      # Without it every badge cost three role_permissions queries: verdict_for
      # plucked, this method re-called verdict_for and plucked again, then
      # plucked a third time itself — multiplied by every chip on a 50-subject
      # page.
      def type_untargeted?(grant, verdict: :__unset)
        verdict = verdict_for(grant) if verdict == :__unset
        return false unless verdict.nil?
        return false if orphaned?(grant)

        role = grant.role
        return false if role.nil? || role.full_access?

        klass = resource_class(grant)
        return false if klass.nil? # unresolvable class is #90's inert, not ours

        keys = persisted_keys(role)
        return false if keys.any? { |key| routed?(key) && targets_route_key?(key, klass.model_name.route_key) }

        # #108: a grant on a PARENT legitimately reaches its children, so a role
        # ticking only `reports#approve` is correct on a Project grant when Report
        # declares `current_scope_parent :project`. That is the CHANGELOG's own
        # headline example, and flagging it would send an operator to a hook that
        # is already right. Silent when any declared chain reaches this class.
        !reachable_through_declared_chain?(klass, keys)
      rescue NameError, ActiveRecord::ActiveRecordError => e
        log_degrade(e)
        false
      end

      # What the operator is told, per state. Kept here so the task and the two
      # views cannot drift into three different wordings for one finding.
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

      # #90's state, not ours: the RECORD is gone and the fix is to remove the
      # grant. Rendering "cannot match" or "check hooks" beside "inert" stacks
      # two badges naming different remedies on one grant, which is the exact
      # confusion this feature exists to end.
      # Role#permission_keys returns STAGED keys when a save failed validation,
      # and inverse_of hands back that same in-memory object. A diagnostic must
      # judge what is persisted, never rejected form input.
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

      # Does any model that declares a parent chain reaching `klass` have a
      # ticked key targeting it? Walks the same declared reflections the
      # resolver walks, so the two cannot disagree about what a chain reaches.
      def reachable_through_declared_chain?(klass, keys)
        CurrentScope::ParentChain.declared_names.any? do |name|
          child = name.safe_constantize
          next false if child.nil?
          next false unless keys.any? { |key| routed?(key) && targets_route_key?(key, child.model_name.route_key) }

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

      # routed?, not include?: the catalog INJECTS the break-glass key onto rows
      # that route an SoD action, so include? is true for a key nothing routes.
      # "Could this ever be gated" is the routed? question.
      def routed?(key)
        CurrentScope.catalog.routed?(key)
      end

      # Starts from the comparison CurrentScope.permission_key makes (does the
      # controller's last path segment equal the record's route key), then
      # WIDENS it: a segment that merely CONTAINS the route key as a whole
      # underscore-delimited word also counts.
      #
      # The widening is not cosmetic. Without it this repo's own dummy fails the
      # false-positive pin: `nested_reports#index` and `external_id_reports#show`
      # both gate Report records, and the strict comparison calls a grant ticking
      # either of them dead. Every widening makes the advisory QUIETER — more
      # false negatives, fewer false positives — which is the only direction it
      # may err, because the cost of missing a dead grant is an operator who
      # investigates one flip later, and the cost of a false alarm is an operator
      # who removes a working grant and stops trusting the diagnostics.
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
