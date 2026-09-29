require "set"

module CurrentScope
  # The denial re-check the report task prints, and the facts preflight reads.
  # A summary of what the checks found. Not a verdict and not a clearance.
  class DenialSurvey
    # Buckets the report already prints, plus the two facts the report does not
    # print: the grant-scan rescue flag and a missing events table.
    Result = Struct.new(
      :rows,
      :blind_rows,
      :initiator_rows,
      :outstanding,
      :resolved,
      :unknown,
      :moot,
      :legacy_model,
      :dead_model,
      :superseded,
      :dead_grants,
      :untargeted_grants,
      :nonconforming_grants,
      :preflight,
      :signals,
      :grant_scan_rescued,
      :unjudgeable_grants,
      :events_table_missing,
      keyword_init: true
    )

    NOT_READY_HEADLINE = "CurrentScope preflight: NOT READY. A check found a problem."
    CANNOT_TELL_HEADLINE = "CurrentScope preflight: CANNOT TELL. A required check could not run."
    NOTHING_TO_ACT_ON_HEADLINE = "CurrentScope preflight: nothing to act on in the checks that ran."

    # The ungated task already prints this limit. Preflight repeats it under
    # Not checked on every run. It does not change the headline.
    CONDITIONAL_SKIP_LIMIT =
      "Limit: this lists only what the callback chain PROVES. A conditional skip " \
      "(skip_before_action only:/except:) does not appear here — set " \
      "config.gating_tripwire = :warn and include CurrentScope::GatingTripwire " \
      "to inventory those at runtime."

    NOT_CHECKED = [
      "Host authentication order. This gem cannot see whether the host authenticates before the gate.",
      "Routes with no recorded traffic. They are absent from this survey.",
      "Denials after a flip are log lines, not ledger rows.",
      CONDITIONAL_SKIP_LIMIT
    ].freeze

    # What assemble returns. The rake task prints this. It does not decide again.
    Answer = Struct.new(
      :headline, :why, :act_on, :moot_count, :moot_line, :not_checked,
      keyword_init: true
    )

    def self.denials
      events_table_missing = false
      rows = []
      blind_rows = []
      initiator_rows = []
      begin
        rows = CurrentScope::Event.where(event: "access.would_deny")
                                  .pluck(:subject, :target_label, :details, :target, :created_at, :id)
        # #73: SoD blind-spot 403s are NOT would_deny (granting won't fix them).
        # Surface them as a separate section so the survey is complete.
        blind_rows = CurrentScope::Event.where(event: "access.sod_blind_spot")
                                        .pluck(:subject, :target_label, :details)
        # #133: an SoD action whose model defines no current_scope_initiator did
        # not 403 — it RAISED. Its own section, because it is the one report-mode
        # outcome that is a 500, and neither granting nor the record hook fixes it.
        initiator_rows = CurrentScope::Event.where(event: "access.sod_initiator_missing")
                                            .pluck(:subject, :target_label, :details)
      rescue ActiveRecord::StatementInvalid => e
        # A missing events table is a returned fact, not an empty ledger, and not
        # an abort. The report task still stops with the migrate sentence before
        # any other section. An unrelated StatementInvalid still raises. A missing
        # column whose message names this table is that unrelated error: it is not
        # an un-migrated host. The empty stand-in rows below must not be read as
        # "nothing to act on".
        raise unless CurrentScope::Event.missing_events_table?(e)

        events_table_missing = true
        rows = []
        blind_rows = []
        initiator_rows = []
      end

      # #134: these two are STATIC — derived from the grants table, not the
      # ledger — so they are present with zero traffic. That is the whole point:
      # a grant that can never match is most likely to exist BEFORE report mode
      # was ever exercised, which is exactly when the ledger is empty.
      # find_each, not a full load: a host's grants table can be large and this is
      # a scan. Verdict computed once and handed to the advisory, which would
      # otherwise recompute it (and re-query role_permissions) per grant.
      # #133: static too, and for the same reason the grant scans are — an SoD
      # action with no initiator behind it exists before report mode is ever
      # exercised, which is exactly when the ledger is empty. Never raises; it
      # degrades to no findings and logs.
      # One scan, carried as a value. Nothing below has to reason about whether
      # some other call has since reset a flag on the module.
      preflight = CurrentScope::SodPreflight.scan
      preflight_rows = preflight.rows

      # #116: the ledger is APPEND-ONLY, so a would_deny row survives the grant that
      # fixes it. Counting rows therefore answers "what was ever denied", while the
      # operator's actual question before flipping to :enforce is "what would STILL
      # be denied". Re-ask the resolver, once per distinct subject and permission
      # rather than once per row, and split the survey on the answer. That
      # outstanding list can reach zero and stay there, which is what makes the
      # rollout loop terminate.
      #
      # Best effort by design, like every other section here: a subject or record
      # that no longer resolves is reported as unknown rather than silently counted
      # as fixed, because "cannot tell" must never read as "ready".
      # Named fields, not a positional tuple (#196 review). Five sums and two set
      # builders read this, and a wrong index is a count that silently disagrees
      # with the headline — which is what the detail-list key got wrong once
      # already. `denials` rather than `count`, so the reader does not shadow
      # Enumerable#count on a Struct. Held in a LOCAL, not a constant: a name as
      # generic as Denial must not become a constant on this class.
      # `record_less` is the RAW recorded flag, which the detail-list key must
      # match against the ledger row; `asked_record_less` is the value the
      # re-check actually used, which for a row written before the flag existed
      # falls back to comparing the GIDs. Two fields because the two jobs are
      # different, and using the raw one for the second silently excluded the
      # oldest rows from being answered at all (#196 review).
      denial_row = Struct.new(:subject_gid, :permission, :target_gid, :denials, :record_less,
                              :asked_record_less, :model, :last_seen, keyword_init: true)

      outstanding = []
      resolved = []
      unknown = []
      # #190: a denial whose TARGET RECORD no longer loads is knowably moot, not
      # "cannot tell". The gate can never be asked about a row that is gone, so the
      # denial cannot recur and must not be counted against the flip. Kept separate
      # from `unknown`, which stays counted, and out of `signals`, because moot
      # needs no operator action.
      moot = []
      # #196: rows written before the ledger recorded the gate's model. They are
      # re-checked the old way, without one, which is the STRICTER question, so a
      # subject a scoped grant already admits reads as outstanding. Counted here
      # so the report can say how much of its own list it cannot vouch for,
      # instead of letting an operator grant a whole controller to clear it.
      legacy_model = []
      # #196 review: a record-less row whose recorded model name no longer loads.
      # It is still ASKED, without a type, because every arm that can allow
      # without one allows with one too; only a denial lands here, and only that
      # denial is the answer the missing type could have changed. Tracked so the
      # report can say which part of its cannot-tell pile this is, and what does
      # and does not move it.
      dead_model = []
      # Keyed on the TARGET too, not just subject and permission: a denial the host
      # will clear with a scoped grant on one record is a different question from
      # the same permission on another record, and collapsing them would re-ask
      # with record: nil and count a scoped grant as permanently outstanding.
      # record_less is part of the KEY, not read off one member: a legacy row (written
      # before the flag existed) and a new one can share a subject, permission and
      # target, and taking either row's value would apply it to the other. A group is
      # therefore uniform by construction, and the legacy rows fall back on their own.
      # The recorded MODEL is part of the key too (#196), for the same reason
      # record_less is: a legacy row that never stored one and a new row that
      # stored nil are different questions, and a group has to be uniform or one
      # member's answer gets applied to the other. `:absent` is the field missing,
      # nil is the field present and empty.
      rows.group_by { |subject_gid, _label, details, target_gid|
        hash = details.is_a?(Hash) ? details : {}
        [ subject_gid, hash["permission"], target_gid, hash["record_less"],
          hash.key?("model") ? hash["model"] : :absent ]
      }.each do |(subject_gid, permission, target_gid, recorded_flag, recorded_model), group|
        pair = denial_row.new(subject_gid: subject_gid, permission: permission, target_gid: target_gid,
                              denials: group.count, record_less: recorded_flag,
                              asked_record_less: nil, model: recorded_model,
                              last_seen: group.filter_map { |row| [ row[4], row[5] ] if row[4] }.max)
        if permission.nil?
          unknown << pair
          next
        end

        # Returns the record, :moot (the class loaded and the row is gone), or
        # :unknown (we cannot tell). The CALLER decides what each means, because the
        # same missing row is moot on a target and unknown on a subject. That locate
        # RAISES rather than returning nil is the contract already stated at
        # app/helpers/current_scope/application_helper.rb#current_scope_gid_label.
        locate = lambda do |gid|
          return :unknown if gid.blank?

          # A nil return is an unparseable GID, which is not evidence of deletion.
          GlobalID::Locator.locate(gid) || :unknown
        rescue ActiveRecord::RecordNotFound
          :moot
        rescue StandardError
          # NameError lands here: a class that no longer resolves is a host we
          # cannot ask, not a record we know is gone.
          :unknown
        end

        subject = locate.call(subject_gid)
        # A dead SUBJECT is UNKNOWN, never moot, and it is judged BEFORE the target,
        # so a row with both a dead subject and a dead target counts as unknown. Do
        # not reorder these two blocks: it silently flips such a row onto the
        # permissive side. A subject can fail to resolve for reasons that are not
        # deletion (a class not loaded in this process, a tenant not connected), and
        # a subject is who a grant is written FOR.
        if subject.is_a?(Symbol)
          unknown << pair
          next
        end

        # Guard writes `target: target || subject`, so a RECORD-LESS denial carries
        # the subject's own GID as its target. Re-asking with the subject as the
        # record would be a different question: the record-less arm of the resolver
        # could no longer fire.
        #
        # Prefer the flag Guard now records. Fall back to comparing GIDs only for
        # rows written before that flag existed, and say so, because the fallback is
        # ambiguous: a denial on the subject's OWN record looks identical to a
        # record-less one, and guessing record-less re-checks on the more
        # permissive arm.
        record_less = recorded_flag.nil? ? (target_gid.blank? || target_gid == subject_gid)
                                         : recorded_flag
        pair.asked_record_less = record_less
        # A recorded target that no longer resolves is NOT the same as no target:
        # re-asking without it would answer a question the ledger never asked.
        record = nil
        unless record_less
          located = locate.call(target_gid)
          case located
          when :moot
            moot << pair
            next
          when :unknown
            unknown << pair
            next
          end
          record = located
        end

        # #196: ask with the model the GATE used. CurrentScope::Guard fills
        # `model:` from the controller's current_scope_model hook on every real
        # request, and the resolver's record-less arm needs it to see a scoped
        # grant at all. Re-asking without it asks a stricter question and calls a
        # subject denied whom the gate admits — and the fix that reading implies
        # is to grant the whole controller to everyone.
        #
        # A name that no longer resolves to a class is UNKNOWN, not allowed:
        # failing closed, the same as every other cannot-tell in this task.
        #
        # Only for a RECORD-LESS row (#196 review). `model:` changes the
        # record-less arm and nothing else, so a row that carries a live record is
        # answerable with or without it. Bailing to `unknown` on a name that no
        # longer constantizes would strand such a row as outstanding for ever,
        # which no grant can clear — the unreachable exit condition #190 fixed,
        # one layer down.
        model = nil
        dead_model_name = false
        if record_less && recorded_model.is_a?(String)
          model = begin
            recorded_model.constantize
          rescue StandardError
            nil
          end
          # collection_type?, not is_a?(Class): a name can survive and come back
          # as something the resolver refuses (a renamed constant, a module, a
          # PORO). Passing it would label the row as re-checked with the gate's
          # type when it was not (#196 review).
          unless model.is_a?(Class) && CurrentScope.resolver.collection_type?(model)
            model = nil
            dead_model_name = true
          end
        end

        still_denied = begin
          !CurrentScope.resolver.allow?(subject: subject, permission: permission,
                                        record: record, model: model)
        rescue StandardError
          nil
        end
        case still_denied
        when true
          # A DENY is the one answer the missing type could have changed, so a
          # dead model name makes it cannot-tell rather than grant-this. An ALLOW
          # needs no such caveat: every arm that can allow without a type allows
          # with one too (#196 review).
          if dead_model_name
            unknown << pair
            dead_model << pair
          else
            outstanding << pair
            # Only a record-less row can turn on the model, so only those are
            # worth qualifying. A legacy row WITH a record is answered identically
            # either way, and naming it would inflate the caveat.
            legacy_model << pair if recorded_model == :absent && record_less
          end
        when false then resolved << pair
        else unknown << pair
        end
      end

      # A grant the row's own type would refuse if it were written today.
      unjudgeable_grants = 0
      grant_scan_rescued = false
      grant_refused_by_declaration = lambda do |grant|
        next false if grant.role.nil?
        # An orphaned grant resolves to nothing (#90), so it is not one of the
        # rows this section is about — and every other section here excludes it
        # for the same reason. Counting it would inflate the total with grants
        # that open nothing and tell the operator they "still resolve".
        next false if grant.respond_to?(:orphaned_resource?) && grant.orphaned_resource?

        # The model's own answer, so the scan and the gate cannot disagree about
        # which class governs a grant. inert on a stale token: a type that no
        # longer loads is #90's inert grant, not a #183 finding.
        klass = grant.current_scope_governing_class(inert_on_error: true)
        next false if klass.nil? || !klass.respond_to?(:current_scope_grants_role?)

        !klass.current_scope_grants_role?(grant.role)
      rescue StandardError => e
        # Both this per-grant rescue and the batch rescue below set the flag.
        # The report warn text stays. The flag is not a report sentence.
        grant_scan_rescued = true
        # SAY it, ONCE. This section is the only tool a host has for finding rows
        # written before a declaration landed, so a swallowed error hides exactly
        # what it exists to surface — but a systemic cause (a host predicate that
        # raises) would otherwise print a line per row and bury the report the
        # operator ran the task for. The rest are counted (#183).
        unjudgeable_grants += 1
        if unjudgeable_grants == 1
          warn "[CurrentScope] could not judge grant ##{grant.id} against " \
               "#{grant.resource_type} (#{e.class}: #{e.message}); " \
               "it is reported as conforming"
        end
        false
      end
      # Keyed on the question that was ASKED, record-lessness included: a
      # self-targeted denial and a record-less one share a target GID, and they
      # are answered by different arms of the resolver. Matching on the three-part
      # key would let a record-bound answer drop a record-less row off the list,
      # which fails open (#196 review).
      replay_key = lambda do |denial|
        [ denial.subject_gid, denial.permission, denial.target_gid, denial.asked_record_less ]
      end
      # The NEWEST model-bearing answer per question, and the questions where a
      # model-bearing row is still denied. A legacy row is answered only when a
      # model-bearing row for the same question came back granted, that row is
      # newer than the legacy one, and no sibling of it is still denied.
      #
      # Newer, because during a rolling deploy an older new-format row would
      # otherwise hide a later old-format denial, and the sentence this prints
      # says "since". Newer is [created_at, id], not created_at alone: two rows
      # written in the same request share a timestamp, and a strict comparison on
      # that alone would refuse the answer and leave a stale denial standing
      # (#196 review). Not-still-denied, because `current_scope_model` may return
      # different types for the same permission, and a granted answer for one of
      # them is no answer for the other.
      answered_with_model = resolved.select { |denial| denial.model.is_a?(String) }
                                    .group_by(&replay_key)
                                    .transform_values { |denials| denials.filter_map(&:last_seen).max }
      still_denied_with_model = outstanding.select { |denial| denial.model.is_a?(String) }
                                           .to_set(&replay_key)
      superseded, outstanding = outstanding.partition do |denial|
        next false unless denial.model == :absent && denial.asked_record_less

        key = replay_key.call(denial)
        answer = answered_with_model[key]
        # <=>, not >: last_seen is a [created_at, id] pair and Array has no >.
        answer && !still_denied_with_model.include?(key) &&
          (denial.last_seen.nil? || (answer <=> denial.last_seen) == 1)
      end
      legacy_model -= superseded

      dead_grants = []
      untargeted_grants = []
      # #183: the declaration is a VALIDATION, so it judges a grant when the row
      # is written and never again. A host that adds a declaration to close a
      # widening has not touched the rows already in the table — and those are
      # exactly the ones the feature was opened for. Name them here, where the
      # other "this grant is not what you think" findings live.
      nonconforming_grants = []
      begin
        CurrentScope::ScopedRoleAssignment.includes(role: :role_permissions)
                                          .in_batches(of: 500) do |relation|
          batch = relation.to_a
          # orphaned? reads the polymorphic resource, which includes() cannot
          # cover — without this the scan costs one extra query per grant.
          CurrentScope::ScopedRoleAssignment.preload_resolvable_resources!(batch)
          batch.each do |grant|
            verdict = CurrentScope::GrantDiagnosis.verdict_for(grant)
            if verdict
              dead_grants << [ grant, verdict ]
            elsif CurrentScope::GrantDiagnosis.type_untargeted?(grant, verdict: verdict)
              untargeted_grants << grant
            end
            nonconforming_grants << grant if grant_refused_by_declaration.call(grant)
          end
        end
      rescue ActiveRecord::ActiveRecordError => e
        grant_scan_rescued = true
        # This scan is an ADDITION to the ledger survey, so a database problem
        # here must not take the whole task down — the would-deny summary is the
        # part a host is mid-rollout depending on. Degrade to no static findings
        # and say so. (cubic)
        warn "[CurrentScope] could not scan scoped grants (#{e.class}: #{e.message}); " \
             "skipping the static grant sections."
        dead_grants = []
        untargeted_grants = []
        nonconforming_grants = []
        # And the count that speaks for that scan: the loop was abandoned, so a
        # partial tally would describe a pass that did not finish (#183).
        unjudgeable_grants = 0
      end

      signals = {
        # Counted in DENIALS, the same unit the detail section totals, so the
        # headline and the list below can never disagree. outstanding carries a
        # per-pair count because the re-check is per pair.
        "would-be denials STILL ungranted (grant these)" =>
          outstanding.sum(&:denials) + unknown.sum(&:denials),
        "scoped grants that can never match" => dead_grants.count,
        "scoped grants worth checking" => untargeted_grants.count,
        "scoped grants their type no longer accepts" => nonconforming_grants.count,
        "SoD actions that will RAISE (500, not grantable)" => preflight_rows.count,
        "SoD blind-spot denials (not grantable)" => blind_rows.count,
        "SoD actions that already RAISED (500, not grantable)" => initiator_rows.count
      }.reject { |_label, count| count.zero? }


      Result.new(
        rows: rows,
        blind_rows: blind_rows,
        initiator_rows: initiator_rows,
        outstanding: outstanding,
        resolved: resolved,
        unknown: unknown,
        moot: moot,
        legacy_model: legacy_model,
        dead_model: dead_model,
        superseded: superseded,
        dead_grants: dead_grants,
        untargeted_grants: untargeted_grants,
        nonconforming_grants: nonconforming_grants,
        preflight: preflight,
        signals: signals,
        grant_scan_rescued: grant_scan_rescued,
        unjudgeable_grants: unjudgeable_grants,
        events_table_missing: events_table_missing
      )
    end

    def self.assemble
      survey = denials
      ungated, missing, name_errors, empty_catalog = gating_walk
      config = CurrentScope.config
      why = []

      survey.signals.each do |label, count|
        why << "#{count} #{label}."
      end
      if ungated.any?
        why << "Ungated controllers, the gate never runs: #{ungated.join(', ')}."
      end
      if config.enforcement != :report
        why << "Enforcement is #{config.enforcement.inspect}, not :report."
      end
      unless config.audit == true || config.audit == :strict
        why << "Audit is #{config.audit.inspect}. It is neither true nor :strict."
      end
      why << "The SoD preflight could not complete." if survey.preflight.degraded?
      if survey.preflight.blind?
        # blind? is also true when degraded? is true. A degraded scan can still
        # have rows. Do not call that list empty.
        why << if survey.preflight.degraded? && survey.preflight.any?
          "The SoD preflight is blind. The finding list is incomplete."
        else
          "The SoD preflight is blind. An empty finding list is not a result."
        end
      end
      if survey.grant_scan_rescued
        why << "The grant scan rescued an error. This run cannot judge every grant."
      end
      if survey.events_table_missing
        why << "The current_scope_events table doesn't exist, so nothing was recorded."
        why << "Run: bin/rails current_scope:install:migrations && bin/rails db:migrate"
      end
      if empty_catalog
        why << "No routed controllers were found in the permission catalog, so nothing was inspected."
      end
      if missing.any?
        why << "Routed paths whose controller class did not load: #{missing.join(', ')}."
      end
      name_errors.each do |path, error_class|
        why << "Loading controller #{path} raised #{error_class}."
      end

      moot_count = survey.moot.sum(&:denials)
      moot_line = if moot_count.zero?
        nil
      else
        "#{moot_count} recorded denial(s) are not work to grant. Those rows name a record that no longer loads."
      end

      problem = survey.signals.any? || ungated.any?
      cannot_tell = config.enforcement != :report ||
        !(config.audit == true || config.audit == :strict) ||
        survey.preflight.degraded? ||
        survey.preflight.blind? ||
        survey.grant_scan_rescued ||
        survey.events_table_missing ||
        empty_catalog ||
        missing.any? ||
        name_errors.any?
      headline = if problem
        NOT_READY_HEADLINE
      elsif cannot_tell
        CANNOT_TELL_HEADLINE
      else
        NOTHING_TO_ACT_ON_HEADLINE
      end

      Answer.new(
        headline: headline,
        why: why,
        act_on: survey.signals,
        moot_count: moot_count,
        moot_line: moot_line,
        not_checked: NOT_CHECKED
      )
    end

    # One controller at a time. A NameError from ungated? is caught here, not
    # inside ungated?, and the walk continues. A later ungated controller still
    # counts as a problem.
    def self.gating_walk
      gating = CurrentScope::GatingReflection.new
      catalog = CurrentScope.catalog
      grouped = catalog.grouped
      ungated = []
      missing = []
      name_errors = []
      # The catalog injects break-glass onto the last path segment. That row
      # can name a controller nobody routes. The ungated task omits it. Do
      # the same here, or a host that turns break-glass on is CANNOT TELL
      # on every run.
      bypass_action = CurrentScope.config.allow_sod_bypass ? catalog.bypass_action : nil
      grouped.each do |controller, actions|
        next if injected_bypass_only?(catalog, controller, actions, bypass_action)

        begin
          if gating.ungated?(controller)
            ungated << controller
          elsif gating.missing_controller?(controller)
            missing << controller
          end
        rescue NameError => e
          # NoMethodError is a NameError. Keep the class, so a bug in the
          # reflection is not described as a controller that failed to load.
          name_errors << [ controller, e.class.name ]
        end
      end
      [ ungated, missing, name_errors, grouped.empty? ]
    end
    private_class_method :gating_walk

    def self.injected_bypass_only?(catalog, controller, actions, bypass_action)
      return false if bypass_action.nil?
      return false if actions.empty? || actions.any? { |action| action != bypass_action }

      !catalog.routed?("#{controller}##{bypass_action}")
    end
    private_class_method :injected_bypass_only?
  end
end
