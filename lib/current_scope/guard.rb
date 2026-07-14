module CurrentScope
  # The enforcement point. Include after Context to gate every action behind
  # its own permission: the current controller#action IS the permission key,
  # so new controllers are gated (fail-closed) the moment they exist.
  #
  # Member actions that need record-level decisions (scoped roles, SoD)
  # declare a private current_scope_record method returning the record. Three
  # rules for the hook:
  #   - it runs for EVERY gated action, collection actions included — return
  #     nil when there is no record
  #   - it runs BEFORE the controller's own before_actions, so it must load
  #     the record itself (memoize so set_* callbacks reuse it)
  #   - key off request.path_parameters, NEVER params: a query-string ?id=
  #     must not let a scoped role on one record unlock a collection action
  #
  #       def current_scope_record
  #         set_report if request.path_parameters[:id]
  #       end
  #
  # Skip the gate for public endpoints with skip_before_action :current_scope_check!.
  # MutationGuard (included here) adds the read-only-while-impersonating gate as
  # its OWN before_action, so it runs first and survives that skip.
  module Guard
    extend ActiveSupport::Concern
    include MutationGuard

    included do
      before_action :current_scope_check!
    end

    private

    def current_scope_check!
      # Record that the gate ran, so an optional GatingTripwire (A4) can tell a
      # gated action from one on a controller that never included Guard.
      @current_scope_checked = true
      permission = "#{controller_path}##{action_name}"

      # An excluded controller can never be granted in the grid, so gating it
      # would lock it to full_access forever — a misconfiguration, not a deny.
      unless CurrentScope.catalog.include?(permission)
        raise CurrentScope::ConfigurationError,
              "\"#{permission}\" is not in the permission catalog (excluded_controllers " \
              "or not routed). Either stop excluding it, or skip the gate here with " \
              "skip_before_action :current_scope_check!."
      end

      record = respond_to?(:current_scope_record, true) ? send(:current_scope_record) : nil

      # The real actor (Current.actor) enters here explicitly — the resolver
      # never reads Current itself (PDP purity). It only matters under SoD
      # :either while impersonating; otherwise actor == subject.
      allowed, reason = CurrentScope.resolver.decide(
        subject: CurrentScope::Current.user, permission: permission,
        record: record, actor: CurrentScope::Current.actor
      )
      raise CurrentScope::AccessDenied.new(permission, reason: reason) unless allowed

      record_sod_bypass(permission, record) if reason == :sod_bypassed
      nudge_on_nil_sod_record(permission, record)
    end

    # Break-glass audit (KTD-1): the resolver stays pure and only reports
    # :sod_bypassed; the Guard — which runs once per REAL gated action, never on
    # advisory allowed_to?/scope_for — records the override exactly once and
    # surfaces it on the response. Guarded to mutations (SoD actions are
    # mutations; the GET/HEAD skip is defense-in-depth). Event.record! is a no-op
    # when config.audit is false, so an audit-off host still permits, records
    # nothing — consistent with the rest of the ledger.
    def record_sod_bypass(permission, record)
      return if request.get? || request.head?

      initiator = record.send(CurrentScope::Resolver::INITIATOR_METHOD)
      CurrentScope::Event.record!(
        event: "sod.bypassed", target: record,
        details: { permission: permission, initiator: initiator&.to_gid&.to_s }
      )
      response.set_header("X-Current-Scope-Reason", "sod_bypassed")
    end

    # A5 dev/test aid (opt-in): the request was ALLOWED, but if it's an SoD
    # action gated with a nil record, the SoD veto was silently skipped — a sign
    # current_scope_record returned nil on a member action. Lives here (the gate
    # seam), not in the shared resolver, so it never fires on advisory
    # allowed_to?/scope_for calls. Prod behavior is unchanged either way.
    def nudge_on_nil_sod_record(permission, record)
      return unless CurrentScope.config.warn_on_nil_sod_record
      return unless record.nil?
      return unless CurrentScope.config.sod_actions.include?(permission.split("#").last)

      Rails.logger&.warn(
        "[CurrentScope] \"#{permission}\" is a separation-of-duties action but was gated with a " \
        "nil record, so the SoD veto was skipped. If this is a member action, current_scope_record " \
        "must return the record; if it's a collection action, this is expected."
      )
    end
  end
end
