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
  # A controller may ALSO declare a private current_scope_model naming the type
  # its collection actions deal in:
  #
  #       def current_scope_model = Report
  #
  # Same discovery rules as current_scope_record (private, fixed name,
  # optional). The Guard threads it to the resolver so the record-less scoped
  # branch can bind to that type instead of matching a scoped grant on ANY
  # type (#50); absent means the type is unknown. A plain method, so a host
  # may branch on action_name for a per-action answer.
  #
  # The declaration is TRUSTED, like current_scope_record: since #65 a listed
  # collection-read gate derives its answer from the declared type's scoped
  # list — full_access included — so declaring the WRONG type opens this
  # controller's reads to subjects holding scoped full_access grants of that
  # type. Review the declaration the way you review the record hook.
  #
  # The two hooks PAIR, they don't substitute: current_scope_model WITHOUT
  # current_scope_record is inert, because declaring no record hook passes
  # NO_RECORD (below) and the record-less branch never runs — the declared
  # type is never consulted. A collection controller opting scoped grants in
  # declares BOTH: `def current_scope_record = nil` plus the model.
  #
  # Skip the gate for public endpoints with skip_before_action :current_scope_check!
  # or, preferably, current_scope_skip_gate!(reason: "…") so the role grid can
  # show declared intent instead of an unexplained "gate not run" badge (#76).
  # MutationGuard (included here) adds the read-only-while-impersonating gate as
  # its OWN before_action, so it runs first and survives that skip.
  module Guard
    extend ActiveSupport::Concern
    include MutationGuard

    # Inheritable whole-controller skip reason from current_scope_skip_gate!.
    # nil means no declared reason (bare skip_before_action or never included).
    class_methods do
      # Prefer the macro over bare skip_before_action so the grid can show
      # "skipped: …" instead of the alarming unexplained badge (#76 / plan 030).
      # only:/except: still perform the skip; the stored reason is the
      # whole-controller annotation when those are absent (row-level grid today).
      def current_scope_skip_gate!(reason:, **options)
        text = reason.to_s.strip
        raise ArgumentError, "current_scope_skip_gate! requires a non-blank reason:" if text.empty?

        # Whole-controller only: only:/except: stays unprovable at row level
        # (KTD-3), so we do not claim the entire controller was deliberately
        # opened. The skip still runs.
        if options[:only].nil? && options[:except].nil?
          self.current_scope_gate_skip_reason = text
        end

        skip_before_action :current_scope_check!, raise: false, **options
      end
    end

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
      # class_attribute so a child inherits a parent's declared reason (#62 shape).
      class_attribute :current_scope_gate_skip_reason, instance_accessor: false, default: nil
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
      # Name excluded-vs-unrouted and the matching regex so the fix is obvious
      # (#44); "not in the catalog" alone hid which of the two was true.
      unless CurrentScope.catalog.include?(permission)
        raise CurrentScope::ConfigurationError, catalog_miss_message(permission)
      end

      record = resolve_current_scope_record
      model = resolve_current_scope_model

      # Stash the declared type for the advisory path (allowed_to? in a view),
      # keyed to THIS controller so a cross-controller question can't borrow it
      # (#50, KTD-6). Additive — the gate decision below reads `model` directly,
      # not the ambient copy.
      #
      # NOT when the record hook is absent (NO_RECORD): the gate skips the
      # record-less branch for NO_RECORD (the R9 inert case), so it DENIES a
      # scoped subject — and the advisory path must agree, not show a link the
      # gate 403s. Stashing the model here without a declared record is the one
      # place the view could diverge from the gate. (#50 review, cubic)
      CurrentScope::Current.collection_model = record.equal?(NO_RECORD) ? nil : model
      CurrentScope::Current.collection_model_path = controller_path

      # Decision *inputs* (subject, permission, record, model, actor) are
      # explicit — the resolver does not read ambient identity for the allow/
      # deny answer. Org-role *lookup* may use Current.memoized_org_role (a
      # per-request cache, not a decision input). Actor only widens SoD under
      # :either while impersonating; otherwise actor == subject.
      allowed, reason = decide_with_report_diagnosis(permission, record, model)
      unless allowed
        # The nudge runs BEFORE the report-mode branch, and that ordering is the
        # whole point of it in a retrofit. Report mode downgrades a :no_grant to
        # an observation and lets the request through — so a nudge placed after
        # the early return would go silent for exactly the host report mode
        # exists for. And a missing record hook is the one gap report mode CANNOT
        # explain on its own: the would_deny row for that action never clears, no
        # matter what you grant, because the gate has no record to match a scoped
        # grant against. This is the line that says why. Log-only either way, so
        # it cannot affect the branch below. (#37/#41 interaction)
        nudge_on_inert_scoped_grant(permission, record, reason)
        nudge_on_undeclared_collection_model(permission, record, reason)

        return report_would_deny(permission, record, model) if report_only_denial?(reason, permission, record)

        # Report mode still 403s the SoD blind spot (correct, fail-closed) but
        # used to do so silently — no log, no ledger, invisible to
        # current_scope:report. Diagnose before the raise so a retrofit host
        # sees the mis-declared record hook they must fix (#73).
        diagnose_report_sod_blind_spot(permission, record, reason)

        raise CurrentScope::AccessDenied.new(
          permission,
          reason: reason,
          permission: permission,
          record: (record.equal?(NO_RECORD) ? nil : record),
          subject: CurrentScope::Current.user
        )
      end

      record_sod_bypass(permission, record) if reason == :sod_bypassed
      nudge_on_nil_sod_record(permission, record)
    end

    # The gate decision, plus report mode's account of the one failure it cannot
    # downgrade and cannot pass through: a model with no current_scope_initiator
    # on an SoD action, which raises and 500s the request (#133).
    #
    # The raise STAYS. Report mode's promise is "nothing changes for users", and
    # this breaks it — but the two candidate repairs are worse. Passing the
    # request through executes an SoD action with the four-eyes veto never
    # consulted, which is #73's escalation with the safety catch removed;
    # downgrading to a 403 dresses a misconfiguration up as an ordinary denial,
    # the silent-weakening pattern this engine keeps getting burned by. So the
    # 500 stands, and what changes is that it stops being the loudest failure
    # with the least reporting: it now names itself in the log and in the ledger,
    # so `rails current_scope:report` accounts for it instead of leaving a host
    # to correlate 500s by hand. SodPreflight is the other half — it finds most
    # of these at boot, before any traffic arrives here at all.
    #
    # Rescues the CLASS and asks the resolver WHY, rather than matching the
    # message: ConfigurationError is raised for more than one cause, and the
    # cause decides which fix the host is sent after.
    def decide_with_report_diagnosis(permission, record, model)
      CurrentScope.resolver.decide(
        subject: CurrentScope::Current.user, permission: permission,
        record: record, model: model, actor: CurrentScope::Current.actor
      )
    rescue CurrentScope::ConfigurationError
      diagnose_report_sod_initiator(permission, record)
      raise
    end

    # #133: report mode only. In :enforce a host has committed to the engine and
    # meets this in their error tracker; report mode is the survey, so the survey
    # is where it has to appear. Mirrors diagnose_report_sod_blind_spot — same
    # shape, same report-only scope, a distinct event because the fix is
    # different (the MODEL's hook, not the controller's).
    def diagnose_report_sod_initiator(permission, record)
      return unless CurrentScope.config.report_only?

      gate_record = record.equal?(NO_RECORD) ? nil : record
      # Ask the resolver (#74) — no second copy of the condition, and no reading
      # of the exception's message.
      return unless CurrentScope.resolver.sod_initiator_missing?(
        permission: permission, record: gate_record
      )

      Rails.logger&.warn(
        "[CurrentScope] report-only: \"#{permission}\" RAISED rather than being reported — " \
        "#{gate_record.class.name} defines no #{CurrentScope::Resolver::INITIATOR_METHOD}, and " \
        "\"#{permission}\" is a separation-of-duties action (config.sod_actions), so the veto " \
        "cannot run and the engine refuses to guess. Report mode does NOT downgrade this: the " \
        "request 500s here exactly as it would under :enforce. Define " \
        "#{CurrentScope::Resolver::INITIATOR_METHOD} on #{gate_record.class.name} (return nil to " \
        "exempt a record), or remove \"#{permission.split('#').last}\" from config.sod_actions. " \
        "See also rails current_scope:report (access.sod_initiator_missing events)."
      )
      record_sod_initiator_missing_event(permission, gate_record)
    end

    def record_sod_initiator_missing_event(permission, record)
      subject = CurrentScope::Current.user
      return if subject.nil?

      # Building the row is rescued SEPARATELY from writing it, and the reason is
      # the latch rather than the rescue. warn_ledger_failure_once is one
      # per-PROCESS one-shot shared by all three report-mode recorders
      # (would_deny, sod_blind_spot, and this one), so a failure that never
      # reached the ledger would consume the single warning the OTHER two still
      # need — and label itself "could not record", sending an operator after a
      # ledger problem that does not exist. Only Event.record! may trip that
      # latch. (#133 — qodo, PR #141)
      begin
        # An unsaved record has no GlobalID, so attribute the row to the subject
        # instead — the model NAME is the fix-carrying detail here, and it rides
        # in details either way.
        target = record if record.respond_to?(:to_gid) && record.try(:persisted?)
        details = {
          permission: permission,
          model: record.class.name,
          fix: "define #{CurrentScope::Resolver::INITIATOR_METHOD} on #{record.class.name}"
        }
      rescue StandardError => e
        Rails.logger&.warn(
          "[CurrentScope] report-only: could not BUILD the access.sod_initiator_missing row " \
          "(#{safe_error_description(e)}) — this is not a ledger failure, so the " \
          "ledger warning is left armed. The request RAISED " \
          "CurrentScope::ConfigurationError (500) either way."
        )
        return nil
      end

      CurrentScope::Event.record!(
        event: "access.sod_initiator_missing", target: target || subject, details: details
      )
    rescue StandardError => e
      # The request is about to 500 on the ConfigurationError being re-raised —
      # say that, rather than claiming an outcome this path does not produce.
      warn_ledger_failure_once(
        e,
        event: "access.sod_initiator_missing",
        request_outcome: "The request RAISED CurrentScope::ConfigurationError (500) — only the " \
                         "access.sod_initiator_missing row is missing."
      )
      nil
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
    # `model` is REQUIRED on both recorders (#196 review). A default would let a
    # future call site write model: nil, which the report reads as knowledge
    # rather than absence: re-checked on the stricter question AND not eligible
    # for the legacy caveat that would tell the operator not to grant for it.
    # That is the #196 false denial again, in the one shape the report cannot
    # flag. Fail at the call site instead.
    def report_would_deny(permission, record, model)
      Rails.logger&.warn(
        "[CurrentScope] report-only: would DENY #{permission.inspect} " \
        "(reason: no_grant) — grant it before setting config.enforcement = :enforce"
      )
      response.set_header("X-Current-Scope-Reason", "would_deny")
      record_would_deny_event(permission, record, model)
    end

    # #73: report mode refuses to *downgrade* an SoD blind-spot denial (the
    # veto never ran), but must not 403 *silently*. Log the cause/fix and
    # record a distinct ledger row — never access.would_deny, because granting
    # the permission will not clear this 403 (the hook is the fix).
    def diagnose_report_sod_blind_spot(permission, record, reason)
      return unless CurrentScope.config.report_only?
      return unless reason == :no_grant
      # Ask the resolver (#74) — no second copy of the skip condition.
      return unless sod_veto_blind_spot?(permission, record)

      Rails.logger&.warn(
        "[CurrentScope] report-only: DENIED #{permission.inspect} because the " \
        "separation-of-duties veto could not run (no usable record for this " \
        "action). This is NOT a missing grant — granting will not clear the 403. " \
        "Declare current_scope_record to return the AR record on this member " \
        "action (or remove the action from config.sod_actions if it is not " \
        "meant to be four-eyes gated). See also rails current_scope:report " \
        "(access.sod_blind_spot events)."
      )
      record_sod_blind_spot_event(permission, record)
    end

    def record_sod_blind_spot_event(permission, record)
      subject = CurrentScope::Current.user
      return if subject.nil?

      target = record.equal?(NO_RECORD) ? nil : record
      # Non-records (String params[:id], etc.) are not GlobalID targets.
      target = nil unless target.respond_to?(:to_gid)

      CurrentScope::Event.record!(
        event: "access.sod_blind_spot",
        target: target || subject,
        details: {
          permission: permission,
          reason: "no_grant",
          blind_spot: true,
          fix: "declare current_scope_record for this SoD member action"
        }
      )
    rescue StandardError => e
      # Blind-spot path returns 403 next — do not claim the request was allowed
      # or that a would_deny row was lost (PR #103 review).
      warn_ledger_failure_once(
        e,
        event: "access.sod_blind_spot",
        request_outcome: "The request was DENIED (403) — only the access.sod_blind_spot row is missing."
      )
      nil
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
    def record_would_deny_event(permission, record, model)
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

      # `target: target || subject` keeps the ledger's target non-nil, which means
      # a record-less denial and a denial ON THE SUBJECT'S OWN RECORD both store
      # the subject's GID. Only this side knows which it was, so say so: the #116
      # report re-asks the resolver and must ask with the same record the gate
      # did. Inferring it from equal GIDs would read a self-targeted denial as
      # record-less and re-check on the more permissive arm.
      # #196: the model the GATE used, so the #116 report can re-ask the same
      # question. Without it the report asks a stricter one — record-less with
      # no type — and reports as denied every subject a scoped grant already
      # admits through current_scope_model. On the bake host that was 406 of 696
      # rows, and the fix it implied was to grant a whole controller to everyone.
      #
      # Recorded ONLY when the gate could use it. With NO_RECORD (the controller
      # declares no record hook) the resolver's record-less arm never runs, so
      # the model is inert; storing it anyway would make the report answer
      # ALLOWED where the gate denies, which is the same bug pointing the other
      # way. Same condition as Current.collection_model above.
      #
      # The key is written with nil for "no usable model here" (see
      # recordable_model_name), and is OMITTED only if building it raises. A row
      # from before this field existed has no key either, and lands in the same
      # population: re-checked without a model, and warned about. nil is
      # knowledge, absent is not.
      details = { permission: permission, reason: "no_grant", record_less: target.nil? }
      # Its own rescue, and deliberately not the one below. `model` is the host's
      # object: a class with an overridden `self.name` that raises would
      # otherwise lose the whole would_deny row AND burn the one per-process
      # warning that sod_blind_spot and sod_initiator_missing still need, then
      # label itself "could not record" and send an operator after a ledger
      # problem that does not exist. This repo settled that argument in PR #93
      # and again in PR #141. Omitting the key is the honest fallback: it puts
      # the row in the population that is warned about.
      begin
        details[:model] = recordable_model_name(record, model)
      rescue StandardError
        details.delete(:model)
      end

      CurrentScope::Event.record!(
        event: "access.would_deny", target: target || subject, details: details
      )
    rescue StandardError => e
      # ponytail: swallow and warn ONCE. An unrecordable observation is a lost
      # log line; a raise here is a 500 on a request report mode promised to pass.
      warn_ledger_failure_once(
        e,
        event: "access.would_deny",
        request_outcome: "The request WAS allowed through — only the access.would_deny row is missing."
      )
      nil
    end

    # The model NAME the report may re-ask with, or nil (#196).
    #
    # nil in three cases, and in every one of them re-asking WITHOUT a type
    # reproduces the gate's answer exactly, so nil is knowledge rather than a
    # gap: the controller declared no record hook, so the gate never reached the
    # record-less arm; it declared no model; or it declared one the resolver
    # itself refuses. That last test is the resolver's own `collection_type?`,
    # the same predicate the gate and SodPreflight use, so this cannot drift
    # from what the gate would accept (#196 review).
    #
    # ONE residual, deliberately undefended: a hook returning an ANONYMOUS class
    # the resolver would accept records nil, because Class#name stays nil until
    # a class is assigned to a constant, and the report then re-checks without a
    # type and can under-report an allow. Closing it needs an anonymous
    # ActiveRecord class in the test app, and this gem's own PolymorphicRegistry
    # and GrantDiagnosis both walk descendants, so that fixture changes what
    # other tests see — it broke one. A host naming an anonymous class here is
    # not a shape anyone has written.
    def recordable_model_name(record, model)
      return nil if record.equal?(NO_RECORD)
      return nil unless model.is_a?(Class)
      return nil unless CurrentScope.resolver.collection_type?(model)

      model.name
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
    #
    # `event` / `request_outcome` are path-specific: would_deny allows the
    # request; sod_blind_spot still 403s — the operator-facing text must not
    # claim the wrong outcome (PR #103).
    def warn_ledger_failure_once(error, event:, request_outcome:)
      return if CurrentScope::Guard.ledger_warning_emitted?

      CurrentScope::Guard.ledger_warning_emitted!
      Rails.logger&.warn(
        "[CurrentScope] report-only: #{ledger_failure_hint(error, event: event)} " \
        "#{request_outcome} This warns once per process."
      )
    end

    # ASKS Event whether this is the un-migrated-table case rather than pattern-
    # matching the message here. Event's signature already excludes missing-COLUMN
    # errors — a partial migration is not an absent table, and its own comment
    # says why: it "would point operators at the wrong fix". A looser test here
    # reintroduced exactly that, telling someone their table was missing while
    # they were looking right at it. (#59 review)
    def ledger_failure_hint(error, event:)
      if CurrentScope::Event.missing_events_table?(error)
        "the current_scope_events table is missing, so #{event} rows are not being " \
        "recorded and `rails current_scope:report` will be incomplete. Run " \
        "`rails current_scope:install:migrations && rails db:migrate`, or set " \
        "config.audit = false if you don't want the ledger."
      else
        "could not record #{event} (#{safe_error_description(error)})."
      end
    end

    # "Class: message", with a fallback when the exception itself is hostile.
    #
    # `e.message` is host-overridable and can raise. Every use of it here is
    # inside a rescue on a path that is ABOUT to re-raise something more
    # important — the ConfigurationError that names the model and both fixes, or
    # a 403 — so a second exception raised while formatting the first would
    # replace it, and the host would lose the message that tells them what to do.
    # This codebase already accepted that argument once for `model.inspect`
    # (PR #93); the same reasoning covers `message`. (#133 — cubic, PR #141)
    def safe_error_description(error)
      "#{error.class}: #{error.message.to_s.truncate(120)}"
    rescue StandardError
      "#{error.class}: (message unavailable)"
    end

    # Why a gated permission is missing from the catalog: excluded by config
    # (name the matching regex) vs never routed. Two different host fixes (#44).
    def catalog_miss_message(permission)
      matched = CurrentScope.config.excluded_controllers.select { |re| controller_path.match?(re) }
      skip_clause =
        "Either stop excluding it, or skip the gate here with " \
        "skip_before_action :current_scope_check!. Skipping the gate leaves this " \
        "controller ungated by CurrentScope — protect it with your own " \
        "authorization (e.g. require_admin!)."

      if matched.any?
        patterns = matched.map(&:inspect).join(", ")
        %("#{permission}" is excluded by config.excluded_controllers (matched #{patterns}). #{skip_clause})
      else
        %("#{permission}" is not in the permission catalog because it is not routed. ) +
          "Add a route for this controller#action, or skip the gate with " \
          "skip_before_action :current_scope_check! if the action is intentional " \
          "(then protect it with your own authorization)."
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

    # The type this controller's collection actions deal in, or nil when the
    # host never declared current_scope_model. Mirrors
    # resolve_current_scope_record, minus the sentinel: for the RECORD,
    # "declared nil" and "declared nothing" are different statements and
    # NO_RECORD keeps them apart; for the TYPE both collapse to the same fact —
    # unknown — so a plain nil carries it.
    def resolve_current_scope_model
      return nil unless respond_to?(:current_scope_model, true)

      send(:current_scope_model)
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

    # A5 dev/test aid (on by default in dev/test, #41): the request was ALLOWED, but if it's an SoD
    # action gated with a nil record, the SoD veto was silently skipped — a sign
    # current_scope_record returned nil on a member action. Lives here (the gate
    # seam), not in the shared resolver, so it never fires on advisory
    # allowed_to?/scope_for calls. Prod behavior is unchanged either way.
    # The denial-side mirror of nudge_on_nil_sod_record (#41): this controller
    # declared NO current_scope_record hook, and the subject holds a scoped grant
    # that would have applied if it had.
    #
    # That is a controller with member actions that forgot the hook. It fails
    # closed — correctly — but the resulting 403 is byte-identical to "you were
    # never granted this", so whoever debugs it goes and stares at the grants,
    # which are fine, instead of the controller, which isn't.
    #
    # Keyed on NO_RECORD, NOT on nil, and the difference is the whole nudge:
    #
    #   - NO_RECORD  = "this controller never said whether there's a record here."
    #     Silence. Scoped grants can't open the gate, so a genuinely-granted
    #     subject is refused and nothing says why. THIS is the bug.
    #   - nil        = "there is no record here", stated deliberately by the host.
    #     Since #49 a scoped role ticking the key OPENS that gate, so a subject
    #     with a matching grant isn't denied at all and there is nothing to nudge
    #     about. Nudging here would fire on every legitimate collection request.
    #
    # (Plan 023 predates #49 and guards on `record.nil?` — which can no longer
    # fire for the case it was written for, and excludes the case that can. Pinned
    # by tests below rather than left to the next reader to rediscover.)
    def nudge_on_inert_scoped_grant(permission, record, reason)
      return unless CurrentScope.config.warn_on_inert_scoped_grant
      return unless reason == :no_grant
      return unless record.equal?(NO_RECORD)

      # Diagnostics must not 500 the request (#74): a transient DB error inside
      # scoped_grant_exists? is log-only, matching record_would_deny_event.
      has_grant =
        begin
          CurrentScope.resolver.scoped_grant_exists?(
            subject: CurrentScope::Current.user, permission: permission
          )
        rescue StandardError => e
          Rails.logger&.warn(
            "[CurrentScope] warn_on_inert_scoped_grant could not check scoped grants " \
            "(#{safe_error_description(e)}); skipping diagnostic for \"#{permission}\"."
          )
          false
        end
      return unless has_grant

      # Says only what the predicate proves. scoped_grant_exists? has no resource
      # filter — it can't have one, the missing record IS the bug — so it
      # establishes that a matching scoped grant exists on SOME record, not that
      # it would have applied to whichever record this action meant. Claiming
      # "would satisfy it" overstates that, and a diagnostic that overstates is
      # how a diagnostic starts being ignored. (#61 review, qodo)
      message =
        "[CurrentScope] denied \"#{permission}\" (no_grant) — this subject holds a scoped grant " \
        "for it on some record, and #{controller_path} declares no current_scope_record, so the " \
        "gate had no record to match it against. If this is a member action, declare the hook " \
        "(`def current_scope_record = set_thing`) — if the subject holds the grant on the record " \
        "in question, that fixes this. If the controller is collection-only, " \
        "`def current_scope_record = nil` says so and lets scoped grants through."

      # R9 (#50): this controller declared current_scope_model WITHOUT
      # current_scope_record — the model hook is INERT, because no record hook
      # means NO_RECORD and the record-less branch (the only reader of the
      # declared type) never runs. That trigger is byte-for-byte this nudge's
      # own, so it is one clause on this line, not a second nudge: two log
      # lines saying the same thing on the same request is the noise the
      # diagnostics contract exists to avoid.
      if respond_to?(:current_scope_model, true)
        message += " NOTE: this controller declares current_scope_model, but that hook is inert " \
                   "without current_scope_record — the record hook is what's missing here."
      end

      Rails.logger&.warn(message)
    end

    # #50's adoption gap, named at the moment it bites: the resolver denied
    # :model_undeclared — a declared collection action (record nil) with no
    # current_scope_model, while a scoped grant explicitly ticks the key. The
    # reason ALREADY proves that whole condition (the resolver derived it), so
    # the predicate here is the reason and nothing else — re-deriving it from
    # record/grants would be the drifting second copy KTD-5 warns about.
    # `record` is taken to mirror its sibling's call shape, not consulted.
    # Log-only; the reason rides X-Current-Scope-Reason with or without this.
    def nudge_on_undeclared_collection_model(permission, _record, reason)
      return unless CurrentScope.config.warn_on_undeclared_collection_model

      # Both labels are the same cell — a scoped grant satisfies the key but
      # the gate had no usable type to bind it to — with different fixes, so
      # each gets its own sentence. :model_invalid names the actual value the
      # hook returned, because "declares no current_scope_model" would be a
      # lie to the host that DID declare one and typo'd it (the release-gate
      # finding this branch exists for).
      case reason
      when :model_undeclared
        # The grant is known to satisfy the key on SOME record of SOME type — a
        # tick, or (on a listed read, #65) a full_access role, which ticks
        # nothing. The missing declaration is exactly why the gate couldn't
        # check which, and it also can't check record liveness — so the fix is
        # named as "may fix", never promised. (#61 wording precedent; the
        # resolver's label-predicate comment relies on this hedge.)
        Rails.logger&.warn(
          "[CurrentScope] denied \"#{permission}\" (model_undeclared) — this is a declared " \
          "collection action (current_scope_record returned nil) and the subject holds a scoped " \
          "grant that satisfies the key, but #{controller_path} declares no current_scope_model, " \
          "so the gate had no type to bind it to and failed closed. Declaring the type this " \
          "collection deals in (`def current_scope_model = TheType`) may fix this — the grant " \
          "must be of that type, and for a listed read its record must still be in the model's " \
          "default scope."
        )
      when :model_invalid
        # Re-read the hook rather than thread the value through the call —
        # keeping the call site at its siblings' 3-arg shape, so a host that
        # collides with this (private, but un-namespaced) method name at the
        # old arity gets its own method called, not an ArgumentError-500 on a
        # denied request (PR #93 review, qodo + cubic). Display-only re-read:
        # the hook is a plain method and the decision is already made.
        model = resolve_current_scope_model
        # A diagnostic must never alter the denial path — an object whose
        # inspect raises would turn this 403 into a 500 (PR #93 review, cubic).
        described = begin
          model.inspect
        rescue StandardError
          "(uninspectable object)"
        end
        Rails.logger&.warn(
          "[CurrentScope] denied \"#{permission}\" (model_invalid) — #{controller_path}'s " \
          "current_scope_model returned #{described}, which is not a concrete " \
          "ActiveRecord model class, so the gate could not bind the record-less check to it " \
          "and failed closed. Return the AR class this collection lists " \
          "(`def current_scope_model = TheType`) — a String, instance, or abstract class " \
          "cannot be matched against scoped grants."
        )
      end
    end

    def nudge_on_nil_sod_record(permission, record)
      return unless CurrentScope.config.warn_on_nil_sod_record
      # Ask the resolver (#74) — do not re-derive "did the veto skip?". A private
      # nil/NO_RECORD copy missed the commonest mistake: a hook returning
      # params[:id] (a String). sod_veto_skipped? is the single definition.
      gate_record = record.equal?(NO_RECORD) ? nil : record
      return unless CurrentScope.resolver.sod_veto_skipped?(permission: permission, record: gate_record)

      shape_hint =
        if gate_record.nil?
          "a nil record"
        else
          "a non-record (#{gate_record.class.name}) — often a hook returning params[:id]"
        end

      Rails.logger&.warn(
        "[CurrentScope] \"#{permission}\" is a separation-of-duties action but was gated with " \
        "#{shape_hint}, so the SoD veto was skipped. If this is a member action, " \
        "current_scope_record must return the AR record; if it's a collection action, this is expected."
      )
    end
  end
end
