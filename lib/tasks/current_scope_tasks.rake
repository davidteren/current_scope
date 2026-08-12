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
                                .pluck(:subject, :target_label, :details)
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
      "would-be denials (grant these)" => rows.count,
      "scoped grants that can never match" => dead_grants.count,
      "scoped grants worth checking" => untargeted_grants.count,
      "SoD actions that will RAISE (500, not grantable)" => preflight_rows.count,
      "SoD blind-spot denials (not grantable)" => blind_rows.count,
      "SoD actions that already RAISED (500, not grantable)" => initiator_rows.count
    }.reject { |_label, count| count.zero? }

    separate.call
    if signals.empty?
      puts "CurrentScope report: nothing found in any category."
    else
      puts "CurrentScope report — #{signals.count} category(ies) with something in them:"
      signals.each { |label, count| puts "  #{count.to_s.rjust(6)}  #{label}" }
    end
    puts
    # The SoD clause only when the host opted into SoD. A project that never set
    # config.sod_actions has no preflight to qualify, and naming one is noise
    # about a feature they do not use — pinned by "no SoD config means no
    # preflight section at all".
    caveat_line = +"  This is a survey, not a clearance: the ledger only knows traffic that " \
                   "has already run."
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

    unless rows.empty?
      separate.call
      grouped = rows.group_by { |subject, _label, _details| subject }

      puts "Would-be denials — grant these to stop them (most-denied first):"
      puts

      grouped.each do |subject_gid, subject_rows|
        label = subject_rows.first[1].presence || subject_gid
        puts "  #{label}#{org_role_suffix.call(subject_gid)}"
        print_permission_counts.call(subject_rows)
        puts
      end

      puts "Total: #{rows.count} would-be denials across #{grouped.size} subject(s)."
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
end
