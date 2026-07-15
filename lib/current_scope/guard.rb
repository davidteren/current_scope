module CurrentScope
  # The enforcement point. Include after Context to gate every action behind
  # its own permission: the current controller#action IS the permission key,
  # so new controllers are gated (fail-closed) the moment they exist.
  #
  # Any controller whose actions take part in record-level decisions (scoped
  # roles, SoD) declares a private current_scope_record method returning the
  # record. Three rules for the hook:
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
  # The hook is a DECLARATION, and the gate reads it as one. Returning nil says
  # "this action has no record" — that is what lets a subject holding only
  # scoped grants through a collection gate, with scope_for narrowing the list
  # (#19). Declaring no hook at all says nothing, so the gate assumes nothing
  # and scoped grants cannot open it (NO_RECORD below) — otherwise a controller
  # that simply forgot the hook would hand a scoped subject every record of its
  # type. Nothing is lost by silence: without a hook, scoped grants could never
  # open a collection gate anyway. A collection-only controller that wants them
  # to says so in one line:
  #
  #       def current_scope_record = nil
  #
  # Skip the gate for public endpoints with skip_before_action :current_scope_check!.
  # MutationGuard (included here) adds the read-only-while-impersonating gate as
  # its OWN before_action, so it runs first and survives that skip.
  module Guard
    extend ActiveSupport::Concern
    include MutationGuard

    # "This controller never said whether there is a record here." Passed to the
    # resolver instead of nil when the controller declares no
    # current_scope_record hook at all.
    #
    # The distinction matters because the resolver honors a scoped grant on a
    # record-less target — that is how a scoped-only subject reaches their index
    # (#19). A declared hook returning nil is the host stating "there is no
    # record here", which is exactly what the contract above asks for, and the
    # resolver can trust it. No hook is not that statement: it is silence, and
    # reading silence as "collection action" lets a controller with member
    # actions hand a scoped subject every record of its type — strictly worse
    # than the 403 it gave before this path existed.
    #
    # Neither nil nor a Class, so the resolver's record-less branch skips it and
    # the decision falls to deny. Org-wide and full_access are unaffected — they
    # never read the record — so silence costs a host nothing it had before:
    # scoped grants could never open a collection gate anyway. Declaring the
    # hook is how you opt in.
    NO_RECORD = Object.new.freeze

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

      record = resolve_current_scope_record

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

    # The record this gate decides against, or NO_RECORD when the controller
    # never declared the hook (see NO_RECORD). A declared hook's answer — record
    # or nil — is passed through exactly as given.
    #
    # Deliberately reads the DECLARATION, not the route. Guessing member-vs-
    # collection from path parameters cannot be made correct: `:id` misses
    # `param: :slug`; "any key not suffixed _id" misses `param: :external_id`
    # and falsely accuses a nested parent with a custom param. Each rule fails
    # on the next routing DSL option, because the route simply does not encode
    # what the host means. The hook does, and the contract above already asks
    # every gated controller to declare it.
    def resolve_current_scope_record
      return NO_RECORD unless respond_to?(:current_scope_record, true)

      send(:current_scope_record)
    end

    # Break-glass audit (KTD-1): the resolver stays pure and only reports
    # :sod_bypassed; the Guard — which runs once per REAL gated action, never on
    # advisory allowed_to?/scope_for — records the override exactly once and
    # surfaces it on the response. Recorded for ANY verb: the guarantee is
    # "every bypass is audited", so if a host ever routes an SoD action to GET,
    # the bypass still leaves its trail rather than slipping through unlogged.
    # Event.record! is a no-op when config.audit is false, so an audit-off host
    # still permits, records nothing — consistent with the rest of the ledger.
    def record_sod_bypass(permission, record)
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
      # NO_RECORD counts: it IS the member-action-with-no-record case this nudge
      # exists to catch, so it must not go quiet just because the Guard now
      # labels that case instead of passing a bare nil.
      return unless record.nil? || record.equal?(NO_RECORD)
      return unless CurrentScope.config.sod_actions.include?(permission.split("#").last)

      Rails.logger&.warn(
        "[CurrentScope] \"#{permission}\" is a separation-of-duties action but was gated with a " \
        "nil record, so the SoD veto was skipped. If this is a member action, current_scope_record " \
        "must return the record; if it's a collection action, this is expected."
      )
    end
  end
end
