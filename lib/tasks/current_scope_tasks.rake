require "set"

namespace :current_scope do
  desc "Apply the #151 grant-column shape to an existing database, idempotently. " \
       "Usage: bin/rails current_scope:repair_schema"
  task repair_schema: :environment do
    # WHY THIS EXISTS SEPARATELY FROM db:migrate.
    #
    # A database built by `db:schema:load` / `db:setup` / `db:test:prepare` —
    # every new app, every CI run, every fresh checkout — comes out with the
    # right column TYPE and the server's default collation, because schema.rb
    # cannot express a MySQL collation. Loading a schema also stamps every
    # migration version as applied, so `db:migrate` has nothing pending and
    # prints nothing. On MySQL that left a host unable to boot, with the boot
    # error prescribing a command that could not possibly fix it.
    #
    # This task re-applies the migration's own logic directly. It is idempotent:
    # where the columns are already correct it changes nothing.
    path = Dir[CurrentScope::Engine.root.join("db/migrate/*_widen_current_scope_polymorphic_ids.rb")].first
    abort "Could not find the widening migration inside the gem." if path.nil?

    load path
    migration = WidenCurrentScopePolymorphicIds.new
    migration.verbose = false
    migration.migrate(:up)

    # Say what this adapter actually did. The binary collation is a MySQL-only
    # step — PostgreSQL and SQLite already compare these columns byte for byte —
    # so claiming it everywhere would tell a PostgreSQL operator their columns
    # were re-collated when nothing of the sort happened.
    shape = "#{CurrentScope::KEY_LIMIT}-character"
    shape += ", binary-collated" if CurrentScope.mysql?(CurrentScope::RoleAssignment.connection)
    puts "CurrentScope grant columns are in the #{shape} shape #151 requires."
  end

  desc "Grant the full-access Owner role to a subject (bootstrap the first admin). " \
       "Usage: bin/rails current_scope:grant SUBJECT_ID=1"
  task grant: :environment do
    id = ENV["SUBJECT_ID"]
    abort "SUBJECT_ID is required, e.g. bin/rails current_scope:grant SUBJECT_ID=1" if id.blank?

    klass = CurrentScope.config.subject_class.constantize
    subject = klass.find_by(id: id)
    abort "No #{klass} with id=#{id}" if subject.nil?

    # grant! seeds Owner on the default path — warn on replacement even when
    # the Owner row does not exist yet (first-time Owner creation).
    prior = CurrentScope::RoleAssignment.find_by(subject: subject)&.role
    if prior && prior.name != "Owner"
      warn "WARNING: #{klass}##{subject.id} already held the #{prior.name.inspect} role — " \
           "replacing it with full-access Owner."
    end

    CurrentScope.grant!(subject)
    puts "Granted the full-access Owner role to #{klass}##{subject.id}."
  end

  namespace :identity do
    desc "Check that the configured subject identity is unique among live rows. " \
         "Usage: bin/rails current_scope:identity:check"
    task check: :environment do
      # Read-only, and deliberately silent: IdentitySetup#unique? / #collisions
      # never prompt, so this task is safe in CI, in cron, and in a deploy hook.
      setup = CurrentScope::IdentitySetup.new
      audited = setup.identity.inspect
      if !setup.checkable?
        # Exit 0: nothing is wrong, but do not claim an answer nobody gave.
        puts "Subject identity #{audited} was NOT checked: that identity object " \
             "does not implement unique?. Implement it, or switch to a column " \
             "identity, if you want this task to answer the question."
      elsif setup.unique?
        puts "Subject identity #{audited} is unique (or is the default primary key)."
      else
        keys = setup.collisions
        if keys.any?
          sample = keys.first(10).map(&:inspect).join(", ")
          abort "Subject identity #{audited} is not unique (#{keys.size} colliding key(s): #{sample})."
        end
        # A host resolver said "not unique" and cannot name a duplicate. Say
        # exactly that, rather than printing a made-up key that looks real.
        abort "Subject identity #{audited} is not unique. The configured resolver " \
              "reports a duplicate but does not list the colliding keys — inspect " \
              "it, or switch to a column identity, which does list them."
      end
    # StatementInvalid too: a subject_class whose table is missing reaches the
    # scan and raises from the adapter, and a diagnostic should not answer that
    # with a backtrace.
    rescue CurrentScope::ConfigurationError, ActiveRecord::StatementInvalid => e
      abort e.message
    end

    desc "Attach a subject to a role by portable identity. Dry-run by default. " \
         "WRITE=1 grants. IDENTITY= column or comma list. SUBJECT= portable key. " \
         "ROLE= name (default Owner). PLACEHOLDER=1 WRITE=1 creates a marked " \
         "stand-in outside production only."
    task setup: :environment do
      CurrentScope::IdentitySetup.new.run
    # ConfigurationError alongside Halt, because operator mistakes reach this
    # task through both. A misspelled IDENTITY column (ColumnResolver's
    # assert_columns!) or a SUBJECT that matches two rows raises
    # ConfigurationError, and printing a stack trace for a typo tells the
    # operator that the gem broke rather than that their input was wrong.
    #
    # RecordInvalid and RecordNotUnique because the WRITE path runs HOST code:
    # a placeholder factory calls create! on the host's own model, which has
    # validations this engine knows nothing about, and Role.find_or_create_by!
    # can lose a race. Those are the operator's problem to fix and deserve the
    # message, not a backtrace. The transaction has already rolled back.
    rescue CurrentScope::IdentitySetup::Halt, CurrentScope::ConfigurationError,
           ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      abort e.message
    end
  end

  desc "Summarize would-be denials recorded in report mode into a starter role grid. " \
       "Usage: bin/rails current_scope:report"
  task report: :environment do
    # The subject's current org-wide role, when resolvable — the grid reads
    # differently if someone already holds a role that just doesn't tick these
    # keys. Best-effort: a rollout aid must not abort everyone else's summary
    # because one subject's record was deleted or its class no longer loads.
    # A lambda, not a def — a rake file's `def` lands on Object.
    org_role_suffix = lambda do |subject_gid|
      subject = GlobalID::Locator.locate(subject_gid)
      role = subject && CurrentScope::RoleAssignment.find_by(subject: subject)&.role
      role ? " — currently #{role.name}" : ""
    rescue StandardError
      ""
    end

    begin
      rows = CurrentScope::Event.where(event: "access.would_deny")
                                .pluck(:subject, :target_label, :details, :target)
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
      # Report mode without the migration records nothing (the ledger degrades and
      # warns once). Reaching for this summary is exactly how a host discovers
      # that, so it must name the fix rather than raise a stack trace at them.
      raise unless e.message.match?(/current_scope_events/i)

      abort "The current_scope_events table doesn't exist, so nothing was recorded.\n" \
            "Run: bin/rails current_scope:install:migrations && bin/rails db:migrate"
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
      pair = [ subject_gid, permission, target_gid, group.count, recorded_flag ]
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
      model = nil
      if recorded_model.is_a?(String)
        model = begin
          recorded_model.constantize
        rescue StandardError
          nil
        end
        unless model.is_a?(Class)
          unknown << pair
          next
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
        outstanding << pair
        # Only a record-less row can turn on the model, so only those are worth
        # qualifying. A legacy row WITH a record is answered identically either
        # way, and naming it would inflate the caveat.
        legacy_model << pair if recorded_model == :absent && record_less
      when false then resolved << pair
      else unknown << pair
      end
    end

    dead_grants = []
    untargeted_grants = []
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
        end
      end
    rescue ActiveRecord::ActiveRecordError => e
      # This scan is an ADDITION to the ledger survey, so a database problem
      # here must not take the whole task down — the would-deny summary is the
      # part a host is mid-rollout depending on. Degrade to no static findings
      # and say so. (cubic)
      warn "[CurrentScope] could not scan scoped grants (#{e.class}: #{e.message}); " \
           "skipping the static grant sections."
      dead_grants = []
      untargeted_grants = []
    end

    # Same rescue the org_role_suffix lambda above needs, for the same reason: a
    # rollout aid must not abort the whole survey because one subject's class was
    # removed. Without it this task now raises NameError where it never did.
    grant_line = lambda do |grant|
      # Through the canonical guard: a non-canonical stored subject_id must not
      # be labeled as the unrelated live record it would cast into (#151).
      subject = grant.current_scope_resolved_record("subject")
      who =
        begin
          subject ? CurrentScope.label_for(subject) : "#{grant.subject_type} ##{grant.subject_id}"
        rescue StandardError
          "#{grant.subject_type} ##{grant.subject_id}"
        end
      "    #{who} — role \"#{grant.role&.name}\" on #{grant.resource_type}##{grant.resource_id}"
    end

    # One running flag, not a per-section list of every section before it. That
    # chain grew a term each time a section was added (#134 added two, #133 two
    # more), and it made every new section an edit to every LATER section's
    # guard — miss one and the task prints a wrong blank line that no test
    # catches. `separate` emits the blank only when something already printed.
    printed_section = false
    separate = lambda do
      puts if printed_section
      printed_section = true
    end

    # THE QUESTION THIS TASK IS RUN TO ANSWER is "can I flip to :enforce yet?",
    # and six independently-gated sections made the reader OR them together by
    # hand. One count line first, so the answer is on screen before the detail.
    #
    # Deliberately NOT a verdict. "Safe to enforce" is not a claim this task can
    # make: the preflight is partial by construction, the ledger is historical
    # and only as complete as the traffic that has run, and neither can see a
    # controller nobody exercised. It reports what it FOUND and names what it
    # cannot see — the same rule the preflight caveat and the ungated task
    # follow. (#133 review)
    signals = {
      # Counted in DENIALS, the same unit the detail section totals, so the
      # headline and the list below can never disagree. outstanding carries a
      # per-pair count because the re-check is per pair.
      "would-be denials STILL ungranted (grant these)" =>
        outstanding.sum { |pair| pair[3] } + unknown.sum { |pair| pair[3] },
      "scoped grants that can never match" => dead_grants.count,
      "scoped grants worth checking" => untargeted_grants.count,
      "SoD actions that will RAISE (500, not grantable)" => preflight_rows.count,
      "SoD blind-spot denials (not grantable)" => blind_rows.count,
      "SoD actions that already RAISED (500, not grantable)" => initiator_rows.count
    }.reject { |_label, count| count.zero? }

    separate.call
    # `moot` is deliberately absent from `signals`: that list is the act-on-this
    # list and a moot denial needs no action. It still decides the headline: a
    # moot-only ledger must not read "nothing FOUND in any category" (there is
    # something, and it is on the moot line below), and must not print "0
    # category(ies)" over an empty list. It still gets a headline, because every
    # other run names itself first and an unheaded report reads as a broken task.
    if signals.any?
      puts "CurrentScope report — #{signals.count} category(ies) with something in them:"
      signals.each { |label, count| puts "  #{count.to_s.rjust(6)}  #{label}" }
    else
      puts "CurrentScope report: nothing #{moot.any? ? 'to act on' : 'found'} in any category."
    end
    if outstanding.empty? && unknown.empty? && (resolved.any? || moot.any?)
      puts
      if moot.any?
        # Two different units in one sentence, so each names its own: resolved
        # counts PAIRS (as the sentence below it always has), moot counts
        # DENIALS (the unit of the headline and of the unknown line).
        puts "  Nothing recorded so far is still outstanding: #{resolved.count} subject/permission pair(s)"
        puts "  re-checked against live grants are granted, and #{moot.sum { |pair| pair[3] }} recorded denial(s) name a"
        puts "  record that no longer loads."
      else
        puts "  Every would-be denial recorded so far is now granted " \
             "(#{resolved.count} subject/permission pair(s) re-checked against live grants)."
      end
      puts "  The ledger still lists them because it is append-only. That is the list"
      puts "  you were waiting to see empty; this is what empty looks like."
    end
    if unknown.any?
      puts
      puts "  #{unknown.sum { |pair| pair[3] }} recorded denial(s) could not be re-checked, because the"
      puts "  subject, the record or the permission no longer resolves. They are counted"
      puts "  as OUTSTANDING above: cannot tell is not the same as ready."
    end
    if moot.any?
      puts
      puts "  #{moot.sum { |pair| pair[3] }} recorded denial(s) name a record that no longer loads (deleted, or hidden"
      puts "  by a default scope). The gate can never be asked about that record again, so"
      puts "  they are NOT counted as outstanding."
    end
    if legacy_model.any?
      puts
      puts "  #{legacy_model.sum { |pair| pair[3] }} of the outstanding denial(s) were recorded BEFORE this task stored the"
      puts "  model the gate used, so they were re-checked without one. That is the stricter"
      puts "  question: a subject a scoped grant admits through current_scope_model reads as"
      puts "  denied here. Do NOT grant a permission to clear these. Exercise the action again"
      puts "  in report mode and read the fresh row, or check one by hand with"
      puts "  CurrentScope.resolver.decide(subject:, permission:, record: nil, model: TheModel)."
    end
    puts
    # The SoD clause only when the host opted into SoD. A project that never set
    # config.sod_actions has no preflight to qualify, and naming one is noise
    # about a feature they do not use — pinned by "no SoD config means no
    # preflight section at all".
    caveat_line = +"  This is a survey, not a clearance: the ledger only knows traffic that " \
                   "has already run, and only requests that resolved a subject. A request " \
                   "that reaches the gate before authentication is downgraded and recorded " \
                   "NOWHERE, so it cannot appear above and WILL be refused after the flip. " \
                   "Confirm your authentication runs before the gate."
    if CurrentScope.config.sod_actions.any?
      caveat_line << " The SoD preflight is also partial by construction (its own note says how)."
      caveat_line << " It could not complete this run." if preflight.degraded?
    end
    puts caveat_line

    # Still the ledger guard, but it no longer RETURNS: the sections below are
    # derived from the grants table, not the ledger. (#134)
    if rows.empty? && blind_rows.empty? && initiator_rows.empty?
      separate.call
      # "No output" is indistinguishable from "the task is broken", and the two
      # likeliest causes are both SILENT: report mode never on, or audit off.
      # Name them — this is the first thing a host runs, and an unexplained blank
      # is how they conclude the feature doesn't work.
      puts "No would-be denials recorded."
      puts
      puts "  config.enforcement is #{CurrentScope.config.enforcement.inspect} " \
           "(needs :report to record any)"
      puts "  config.audit is #{CurrentScope.config.audit.inspect} " \
           "(needs true or :strict — the ledger is where these rows live)"
      puts
      puts "With both on, exercise the app or run your suite, then re-run this."
      # NOT `next`. The sections below are derived from the grants table and the
      # routes, not the ledger, so they are present with zero traffic — which is
      # exactly when a grant that can never match is most likely to exist.
      # Returning here would hide them in that case. The config explanation
      # above still prints, because "nothing was recorded" stays true and
      # unexplained silence is how a host concludes the feature does not
      # work. (#134) The blank line before whatever follows is `separate`'s job
      # now, so this branch no longer has to look ahead at the other sections.
    end

    # ponytail: group in Ruby, not SQL. `details` is a JSON column and querying
    # into it is adapter-specific; this is a rollout aid run by hand over a
    # transitional table, so portability beats a smarter query.
    #
    # Shared tally so would_deny and sod_blind_spot sections cannot drift on
    # ordering / unknown-permission handling (PR #103 review).
    print_permission_counts = lambda do |event_rows|
      event_rows
        .group_by { |_s, _l, details| details.is_a?(Hash) ? details["permission"] : nil }
        .transform_values(&:count)
        .sort_by { |permission, count| [ -count, permission.to_s ] }
        .each { |permission, count| puts "    #{count.to_s.rjust(5)}x  #{permission || '(unknown)'}" }
    end

    # Only the pairs still outstanding, so this list agrees with the headline. A
    # resolved row stays in the ledger forever and printing it here is what made
    # the old survey unreadable: a finished rollout showed a long list under a
    # count of zero. `moot` is left out for the same reason it is left out of the
    # headline: this is the grant-these list and a moot denial cannot be granted.
    # Pinned by "the headline counts only outstanding denials and the moot line
    # counts denials".
    open_keys = (outstanding + unknown).to_set { |gid, permission, target, _count, flag| [ gid, permission, target, flag ] }
    open_rows = rows.select do |subject_gid, _label, details, target_gid|
      hash = details.is_a?(Hash) ? details : {}
      open_keys.include?([ subject_gid, hash["permission"], target_gid, hash["record_less"] ])
    end

    unless open_rows.empty?
      separate.call
      grouped = open_rows.group_by { |subject, _label, _details| subject }

      puts "Would-be denials still outstanding — grant these to stop them (most-denied first):"
      puts

      grouped.each do |subject_gid, subject_rows|
        label = subject_rows.first[1].presence || subject_gid
        puts "  #{label}#{org_role_suffix.call(subject_gid)}"
        print_permission_counts.call(subject_rows)
        puts
      end

      puts "Total: #{open_rows.count} outstanding would-be denial(s) across " \
           "#{grouped.size} subject(s)."
      if resolved.any?
        puts "#{resolved.count} more subject/permission pair(s) were recorded and are " \
             "now granted; the ledger keeps them because it is append-only."
      end
    end

    unless dead_grants.empty?
      separate.call
      puts "Scoped grants that can never match — granting more will not help:"
      puts
      dead_grants.group_by { |_g, verdict| verdict }.each do |verdict, pairs|
        puts "  #{CurrentScope::GrantDiagnosis.verdict_label(verdict)}"
        pairs.each { |grant, _v| puts grant_line.call(grant) }
        puts "    → #{CurrentScope::GrantDiagnosis.verdict_fix(verdict)}"
        puts
      end
      puts "Total: #{dead_grants.count} grant(s) that cannot match any gated action."
    end

    unless untargeted_grants.empty?
      separate.call
      puts "Worth checking — no ticked key targets this grant's type:"
      puts
      untargeted_grants.each { |grant| puts grant_line.call(grant) }
      puts
      puts "  #{CurrentScope::GrantDiagnosis.untargeted_caveat}"
    end

    # An EMPTY preflight still speaks when SoD is on. Suppressing the section
    # entirely made a check that blew up (a host hook that raises, no database
    # connection yet, a controller that will not load) look identical on stdout
    # to a check that ran clean — and the PARTIAL caveat, the thing that stops
    # this being read as a verdict, lived inside the suppressed branch. The
    # degrade warning goes to the log, not to the terminal the operator is
    # reading right before an enforce flip. Same rule as the ungated task: a
    # vacuous all-clear is worse than a blank. (#133 review)
    if preflight_rows.empty? && CurrentScope.config.sod_actions.any?
      separate.call
      if preflight.degraded?
        puts "Separation-of-duties preflight: COULD NOT COMPLETE — this section is incomplete."
        puts
        # The reason printed HERE rather than "see the log": an operator reading
        # a terminal must not be sent off to find a log file.
        puts "  #{CurrentScope::SodPreflight.skip_summary(preflight)}"
        puts "  Do NOT read the absence of findings below as an all-clear."
      else
        puts "Separation-of-duties preflight: inspected #{preflight.inspected} of " \
             "#{preflight.in_scope} routed SoD action(s); none named a model missing " \
             "#{CurrentScope::Resolver::INITIATOR_METHOD}."
        if preflight.blind?
          puts
          puts "  NOTHING was inspected — none of those controllers declares " \
               "current_scope_model, so there was nothing for this check to read. This is " \
               "not an all-clear."
        end
      end
      puts
      puts "  #{CurrentScope::SodPreflight.caveat}"
    end

    unless preflight_rows.empty?
      separate.call
      puts "Separation-of-duties actions that will RAISE (500) — not a denial, a misconfiguration:"
      puts
      preflight_rows.each do |permission, model|
        puts "    #{permission} — #{model.name} defines no " \
             "#{CurrentScope::Resolver::INITIATOR_METHOD}"
      end
      puts
      # SHARED with the boot warning, not re-spelled. The remedies are not
      # coequal on a list that can be wrong — defining the hook wires a control,
      # removing the action deletes one — and a private copy here is how that
      # correction reached one surface and not the other for a commit. (#133)
      puts "  #{CurrentScope::SodPreflight.fix_line}"
      puts "  Report mode does NOT downgrade these — the request 500s exactly as it would " \
           "under :enforce."
      puts
      puts "  #{CurrentScope::SodPreflight.caveat}"
    end

    unless blind_rows.empty?
      separate.call
      puts "SoD blind-spot denials — NOT fixed by granting (declare current_scope_record):"
      puts
      print_permission_counts.call(blind_rows)
      puts
      puts "Total: #{blind_rows.count} blind-spot 403(s). Granting these permissions will not " \
           "clear them — fix the record hook (or remove the action from config.sod_actions)."
    end

    # #133: the traffic-found half. The static section above catches these only
    # where a controller declares current_scope_model; these rows are the ones
    # that reached a real request first, so they name the model the gate ACTUALLY
    # held — a proof where the static list is a lead.
    unless initiator_rows.empty?
      separate.call
      puts "SoD actions that RAISED (500s) — NOT fixed by granting, a missing " \
           "current_scope_initiator:"
      puts
      initiator_rows
        .group_by { |_s, _l, details| details.is_a?(Hash) ? [ details["permission"], details["model"] ] : nil }
        .transform_values(&:count)
        .sort_by { |pair, count| [ -count, pair.to_a.map(&:to_s) ] }
        .each do |pair, count|
          permission, model = pair
          puts "    #{count.to_s.rjust(5)}x  #{permission || '(unknown)'} — " \
               "#{model || '(unknown model)'}"
        end
      puts
      puts "Total: #{initiator_rows.count} raised request(s). These are NOT denials and granting " \
           "changes nothing — define #{CurrentScope::Resolver::INITIATOR_METHOD} on each model " \
           "listed (return nil to exempt a record), or remove the action from config.sod_actions."
    end
  end

  desc "Inventory the routed controllers that provably never run the gate — the static " \
       "half of the ungated-surface audit (config.gating_tripwire = :warn is the runtime half). " \
       "Usage: bin/rails current_scope:ungated"
  task ungated: :environment do
    # One reflection for the whole walk — its request object memoizes (KTD-8).
    # A broken controller body's NameError propagates on purpose (KTD-2): a
    # rescue here would report a broken controller as gated.
    gating = CurrentScope::GatingReflection.new
    catalog = CurrentScope.catalog
    grouped = catalog.grouped

    # The catalog injects the break-glass key onto any row routing an SoD
    # action, and that grant is LIVE even on an ungated controller — honored by
    # whatever gated controller decides SoD on the record (the grid's own
    # KTD-9 exemption). Printing it under "grants nothing" would tell an
    # operator the most sensitive grant in the grid is inert. Strip it from
    # the listing and say so once. Only the INJECTED key is stripped —
    # catalog.routed? keeps a real routed action that merely shares the bypass
    # name in the audit, because omitting it would hide a real fail-open route.
    # The catalog also owns the permission parse (split("#", -1) + shape
    # checks) — a loose split here would accept a malformed value. (#79 review)
    bypass_action = CurrentScope.config.allow_sod_bypass ? catalog.bypass_action : nil
    stripped_bypass = false

    # Build the printable rows BEFORE deciding emptiness: a synthetic
    # bypass-only row (a namespace-only SoD resource) reflects as "ungated"
    # while routing nothing, and a header over an empty body reads as a broken
    # task. Rows first, then branch on what there is to say.
    rows = grouped.keys.sort.filter_map { |controller|
      next unless gating.ungated?(controller)

      actions = grouped[controller].sort
      if bypass_action && actions.include?(bypass_action) && !catalog.routed?("#{controller}##{bypass_action}")
        actions -= [ bypass_action ]
        stripped_bypass = true
      end
      next if actions.empty? # nothing routed here — nothing to audit

      [ controller, actions ]
    }

    if grouped.empty?
      # A vacuous all-clear is worse than a blank: with nothing routed there
      # was nothing to inspect, and "every routed controller has the callback"
      # is technically true of an empty set and completely misleading.
      puts "No routed controllers found in the permission catalog — nothing was " \
           "inspected. Check your routes and config.excluded_controllers."
    elsif rows.empty?
      # An unexplained blank reads as "the task is broken" — and a bare blank
      # would also overclaim. Claim only what the reflection proved: nothing
      # was PROVEN ungated. A route whose controller doesn't resolve is
      # unclassified, not vouched for (#43 owns that badge) — "every controller
      # has the callback" would vouch for rows nobody inspected.
      puts "No controller was proven ungated. (A routed path whose controller " \
           "does not resolve is unclassified, not verified — see issue #43.)"
    else
      puts "Provably ungated — current_scope_check! is absent from these controllers' " \
           "callback chains, so the gate never runs there:"
      puts
      rows.each { |controller, actions| puts "  #{controller} (#{actions.join(', ')})" }
      puts
      puts "Ticking these in the role grid grants nothing until the gate runs. " \
           "If a controller inherited a skip, re-assert before_action " \
           ":current_scope_check! on it; if it never had the gate, include " \
           "CurrentScope::Guard."
      if stripped_bypass
        puts
        puts "(#{bypass_action} omitted from the listing — break-glass stays LIVE " \
             "even on an ungated controller; see the role grid's exempt note.)"
      end
    end

    # The limit of the proof, stated even when nothing is listed (KTD-3): a
    # conditional skip (skip_before_action only:/except:) leaves the callback
    # PRESENT wearing a condition — unprovable by reflection, so never shown
    # here even though some of its actions really run open. The runtime half
    # catches those.
    puts
    puts "Limit: this lists only what the callback chain PROVES. A conditional skip " \
         "(skip_before_action only:/except:) does not appear here — set " \
         "config.gating_tripwire = :warn and include CurrentScope::GatingTripwire " \
         "to inventory those at runtime."
  end

  namespace :definitions do
    # A lambda, not a def — a rake file's `def` lands on Object.
    resolve_actor = lambda do
      return unless CurrentScope.config.audit

      id = ENV["ACTOR_ID"]
      abort "ACTOR_ID is required, e.g. ACTOR_ID=1" if id.blank?

      klass = CurrentScope.config.resolved_subject_class
      actor = klass.find_by(id: id)
      abort "No #{klass} with id=#{id}" if actor.nil?

      actor
    end

    apply_document = lambda do |path, snapshot_path: nil, rolling_back: false|
      document = CurrentScope::DefinitionsDocument.parse(path)
      diff = document.diff
      if diff.empty?
        puts "No changes."
        return
      end

      puts diff
      confirm = ENV["CONFIRM"] == "1"
      interactive = !confirm && $stdin.tty? && ENV["CI"].to_s.empty?
      # Ask for ACTOR_ID before the operator types yes. Skip it only when apply
      # is about to refuse for a missing confirm, because that is the message
      # the operator needs first.
      actor = resolve_actor.call unless !confirm && !interactive && document.confirm_required?

      if interactive
        $stderr.print "Apply this change? Type yes: "
        abort "Aborted." unless $stdin.gets.to_s.strip == "yes"
        confirm = true
      end

      undo_path = document.snapshot_destination(snapshot_path)
      document.apply(
        confirm: confirm, actor: actor, snapshot_path: undo_path,
        event: rolling_back ? "definitions.rolled_back" : "definitions.applied"
      )
      puts rolling_back ? "Rolled back role definitions from #{path}." : "Applied role definitions from #{path}."
      puts "Undo point written to #{undo_path}."
    rescue CurrentScope::DefinitionsDocument::Error, CurrentScope::ConfigurationError => e
      abort e.message
    end

    desc "Export live role definitions to YAML. Usage: bin/rails current_scope:definitions:export FILE=config/current_scope/roles.yml"
    task export: :environment do
      path = ENV["FILE"]
      abort "FILE is required, e.g. bin/rails current_scope:definitions:export FILE=roles.yml" if path.blank?

      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      File.write(path, CurrentScope.export_definitions)
      puts "Wrote role definitions to #{path}."
    end

    desc "Print the diff of a definitions document vs live roles. Usage: bin/rails current_scope:definitions:diff FILE=roles.yml"
    task diff: :environment do
      path = ENV["FILE"]
      abort "FILE is required, e.g. bin/rails current_scope:definitions:diff FILE=roles.yml" if path.blank?
      abort "No file at #{path}" unless File.file?(path)

      diff = CurrentScope.diff_definitions(path)
      if diff.empty?
        puts "No changes."
      else
        puts diff
      end
    end

    desc "Apply a definitions document. CONFIRM=1 required on production or a populated roles table. FILE= document. Usage: bin/rails current_scope:definitions:import FILE=roles.yml CONFIRM=1 ACTOR_ID=1"
    task import: :environment do
      path = ENV["FILE"]
      abort "FILE is required, e.g. bin/rails current_scope:definitions:import FILE=roles.yml" if path.blank?
      abort "No file at #{path}" unless File.file?(path)

      apply_document.call(path, snapshot_path: "#{path}.pre.yml")
    end

    desc "Roll back to a pre-apply snapshot. SNAPSHOT= path. CONFIRM=1 as for import. Usage: bin/rails current_scope:definitions:rollback SNAPSHOT=roles.yml.pre.yml CONFIRM=1 ACTOR_ID=1"
    task rollback: :environment do
      path = ENV["SNAPSHOT"]
      abort "SNAPSHOT is required, e.g. bin/rails current_scope:definitions:rollback SNAPSHOT=roles.yml.pre.yml" if path.blank?
      abort "No snapshot at #{path}" unless File.file?(path)

      apply_document.call(path, rolling_back: true)
    end
  end
end
