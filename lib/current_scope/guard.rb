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

    class << self
      # Warn-once latch for a failed would-be-denial recording, mirroring
      # Event.warn_missing_events_table_once. Lives on the module, not the
      # controller: the failure is per-process (a missing table, a dead
      # connection), so per-instance state would warn once per request and
      # defeat the point.
      #
      # ponytail: a plain ivar, not a Mutex. Worst case under a race is a second
      # warning line — the thing being prevented is a flood, not a duplicate.
      def ledger_warning_emitted? = @ledger_warning_emitted
      def ledger_warning_emitted! = @ledger_warning_emitted = true

      # Test seam: the latch would otherwise leak across examples, silently
      # disarming the warning for every test after the first and making the
      # suite order-dependent.
      def reset_ledger_warning! = @ledger_warning_emitted = false
    end

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
      unless allowed
        return report_would_deny(permission, record) if report_only_denial?(reason, permission, record)

        raise CurrentScope::AccessDenied.new(permission, reason: reason)
      end

      record_sod_bypass(permission, record) if reason == :sod_bypassed
      nudge_on_nil_sod_record(permission, record)
    end

    # Report mode lifts EXACTLY ONE wall: :no_grant — "nobody has granted this
    # subject this permission yet", which is the entire state of a host that has
    # mounted the gate and not yet seeded its grants. That is the thing report
    # mode exists to survey.
    #
    # Matched POSITIVELY, on one reason, and that is the whole design. Every
    # other denial is a real refusal about a real rule and must still 403:
    # :sod_veto (relaxing it lets an initiator actually self-approve — a fraud
    # action executed, not a role gap surfaced), :impersonation_gate, and
    # :not_full_access (the management console — report mode must never hand out
    # the UI where grants are made).
    #
    # An "everything except the vetoes I know about" rule would have been correct
    # the day it was written and wrong by the next release: :not_full_access did
    # not exist when this was designed, and it is excluded here by construction
    # rather than by anyone remembering to add it. New reasons are refusals until
    # someone deliberately says otherwise — fail-closed, applied to the mode
    # itself.
    #
    # ...but :no_grant is not always the innocent reason it looks like. See below.
    def report_only_denial?(reason, permission, record)
      CurrentScope.config.report_only? &&
        reason == :no_grant &&
        !sod_veto_blind_spot?(permission, record)
    end

    # The SoD blind spot: a :no_grant that is NOT evidence the veto approved.
    #
    # The veto has nothing to measure without a record, so the resolver skips it
    # and the decision falls through to the ordinary grant check. What comes back
    # is :no_grant — indistinguishable from an ordinary missing grant, but meaning
    # "nobody asked the veto", not "the veto passed".
    #
    # In :enforce that costs nothing; :no_grant is a 403 either way, so the
    # skipped veto never decides anything (config.warn_on_nil_sod_record exists to
    # surface it on the ALLOW path). Report mode is what turns it into a hole:
    # :no_grant is exactly what it downgrades, so a host that mis-declares
    # current_scope_record on an SoD action gets the action EXECUTED with the
    # four-eyes rule never consulted. The subject could be the initiator. Nobody
    # checked.
    #
    # So report mode declines to speak where the veto couldn't, and downgrades
    # only a denial the veto actually saw and passed. This costs a retrofitting
    # host nothing real: an SoD action reached without a record is a
    # misconfiguration they must fix regardless, and it still 403s as it does
    # today.
    #
    # ASKS the resolver rather than re-deriving "did the veto run" — the resolver
    # owns that condition and a second copy would drift, with the drifting copy
    # being the one guarding the fraud control. An earlier draft of this did
    # enumerate its own "record-less" set (nil, NO_RECORD, Class) and missed the
    # commonest mistake of all: a hook returning `params[:id]`, a String, which
    # the resolver skips the veto for but that guess would have waved through.
    def sod_veto_blind_spot?(permission, record)
      CurrentScope.resolver.sod_veto_skipped?(permission: permission, record: record)
    end

    # Observe and proceed.
    def report_would_deny(permission, record)
      Rails.logger&.warn(
        "[CurrentScope] report-only: would DENY #{permission.inspect} " \
        "(reason: no_grant) — grant it before setting config.enforcement = :enforce"
      )
      response.set_header("X-Current-Scope-Reason", "would_deny")
      record_would_deny_event(permission, record)
    end

    # R3: report mode NEVER raises — that is its whole promise, and it has to hold
    # regardless of audit posture or the state of the ledger.
    #
    # Every other caller of Event.record! is a mutation being performed, where
    # :strict re-raising to roll back an unaudited change is exactly right. This
    # is not a mutation: it observes a request that is being let through anyway.
    # Inheriting that raise would mean a host running audit = :strict who hasn't
    # run the events migration 500s on every ungranted request — the opposite of
    # what report mode promises, landing on the exact host it exists for.
    #
    # The rescue wraps ONLY this call. Event.record! is the one thing here with a
    # documented raise contract, so it is the one thing worth catching; a broad
    # rescue over the whole observation would also swallow a broken logger or
    # response, which are app-fatal anyway and shouldn't be hidden. (#59 review)
    def record_would_deny_event(permission, record)
      subject = CurrentScope::Current.user
      # No ambient subject ⇒ nothing to attribute the row to, and Event.record!
      # raises on a nil actor. Guard on the SUBJECT, not on `target` — a record
      # can be non-nil while the subject is nil.
      return if subject.nil?

      # NO_RECORD (the controller declared no hook) and nil (it declared "no
      # record here") both mean there is nothing to attribute the row to but the
      # subject. Compared by identity — NO_RECORD is an Object instance, so
      # `is_a?` would match every record there is.
      target = record.equal?(NO_RECORD) ? nil : record

      CurrentScope::Event.record!(
        event: "access.would_deny", target: target || subject,
        details: { permission: permission, reason: "no_grant" }
      )
    rescue StandardError => e
      # ponytail: swallow and warn ONCE. An unrecordable observation is a lost
      # log line; a raise here is a 500 on a request report mode promised to pass.
      warn_ledger_failure_once(e)
      nil
    end

    # The failure this catches is PERSISTENT, not incidental: :report + audit
    # :strict + an un-migrated events table fails identically on every request.
    # Warning per-request floods the log with one repeated line and buries the
    # thing the operator actually needs — that the ledger is empty because the
    # table is missing, and what to do about it. And it is the exact situation
    # report mode exists for, so it is the one a host is most likely to be in.
    #
    # Warn-once per process, mirroring Event.warn_missing_events_table_once —
    # the same failure, the same treatment. (#59 review) The message names the
    # fix for a missing table and otherwise reports the real error, because
    # telling someone with a dead connection to run migrations sends them after
    # the wrong problem.
    def warn_ledger_failure_once(error)
      return if CurrentScope::Guard.ledger_warning_emitted?

      CurrentScope::Guard.ledger_warning_emitted!
      Rails.logger&.warn("[CurrentScope] report-only: #{ledger_failure_hint(error)} " \
                         "The request WAS allowed through — only the access.would_deny " \
                         "row is missing. This warns once per process.")
    end

    def ledger_failure_hint(error)
      if error.is_a?(ActiveRecord::StatementInvalid) && error.message.include?("current_scope_events")
        "the current_scope_events table is missing, so would-be denials are not being " \
        "recorded and `rails current_scope:report` will be empty. Run " \
        "`rails current_scope:install:migrations && rails db:migrate`, or set " \
        "config.audit = false if you don't want the ledger."
      else
        "could not record a would-be denial (#{error.class}: #{error.message.to_s.truncate(120)})."
      end
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
