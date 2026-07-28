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
        role = grant.role
        return nil if role.nil? || role.full_access?

        keys = role.permission_keys
        return :no_permissions if keys.empty?
        return :unrouted_permissions if keys.none? { |key| routed?(key) }

        nil
      rescue StandardError
        # A diagnostic must not break the page or the task that renders it.
        nil
      end

      # Advisory. Silent whenever verdict_for speaks — a weaker second sentence
      # about the same grant is noise, and the stronger one already names the
      # fix.
      def type_untargeted?(grant)
        return false unless verdict_for(grant).nil?

        role = grant.role
        return false if role.nil? || role.full_access?

        route_key = route_key_for(grant)
        return false if route_key.nil? # unresolvable class is #90's inert, not ours

        role.permission_keys.none? { |key| targets_route_key?(key, route_key) }
      rescue StandardError
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

      # routed?, not include?: the catalog INJECTS the break-glass key onto rows
      # that route an SoD action, so include? is true for a key nothing routes.
      # "Could this ever be gated" is the routed? question.
      def routed?(key)
        CurrentScope.catalog.routed?(key)
      end

      def route_key_for(grant)
        klass = grant.resource_type&.safe_constantize
        return nil unless klass.respond_to?(:model_name)

        klass.model_name.route_key
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
        segment = key.split("#").first.to_s.split("/").last.to_s
        return true if segment == route_key

        segment.end_with?("_#{route_key}") || segment.start_with?("#{route_key}_")
      end
    end
  end
end
