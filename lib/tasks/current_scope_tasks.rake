require "set"

namespace :current_scope do
  desc "Apply the #151 grant-column shape to an existing database, idempotently. " \
       "Usage: bin/rails current_scope:repair_schema"
  task repair_schema: :environment do
    # WHY THIS EXISTS SEPARATELY FROM db:migrate.
    #
    # A database built by `db:schema:load` / `db:setup` / `db:test:prepare` —
    # every new app, every CI run, every fresh checkout — comes out with the
    # right column TYPE, and with the server's default collation whenever that
    # schema.rb was dumped from PostgreSQL or SQLite, which carry no per-column
    # collation for Rails to write down. A dump taken from MySQL does carry one
    # (#194). Loading a schema also stamps every
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
    # exec_migration against the GRANT MODELS' pool, not `migrate` (#193
    # review). `Migration#migrate` runs on
    # ActiveRecord::Tasks::DatabaseTasks.migration_connection, which is the
    # DEFAULT database. A host that puts the engine's tables on a second
    # connection would have watched this task report success against the wrong
    # database while the one the boot refusal named stayed unrepaired, and boot
    # kept failing — and the refusal now names that database, so the promise is
    # explicit.
    # The ENGINE's own base, not one concrete model: this migration alters both
    # grant tables, and CurrentScope::RoleAssignment and ScopedRoleAssignment
    # both inherit CurrentScope::ApplicationRecord, so its pool is the one that
    # holds them. A host that repoints only one of the two concrete models is
    # past what a single pass can repair, and the boot refusal names the
    # database it judged so they can see which one is still wrong.
    CurrentScope::ApplicationRecord.connection_pool.with_connection do |conn|
      migration.exec_migration(conn, :up)
    end

    # Say what this adapter actually did. The binary collation is a MySQL-only
    # step — PostgreSQL and SQLite already compare these columns byte for byte —
    # so claiming it everywhere would tell a PostgreSQL operator their columns
    # were re-collated when nothing of the sort happened.
    shape = "#{CurrentScope::KEY_LIMIT}-character"
    # The same two-name test the guard uses, or this line would understate what
    # the migration just did on a host whose adapter key does not say mysql.
    shape += ", binary-collated" if CurrentScope.mysql_config?(
      CurrentScope::ApplicationRecord.connection_pool.db_config
    )
    puts "CurrentScope grant columns are in the #{shape} shape #151 requires."
  end

  desc "Grant the Owner role to a subject (bootstrap the first admin). " \
       "On a fresh seed Owner is full-access. Usage: bin/rails current_scope:grant SUBJECT_ID=1"
  task grant: :environment do
    id = ENV["SUBJECT_ID"]
    abort "SUBJECT_ID is required, e.g. bin/rails current_scope:grant SUBJECT_ID=1" if id.blank?

    klass = CurrentScope.config.subject_class.constantize
    subject = klass.find_by(id: id)
    abort "No #{klass} with id=#{id}" if subject.nil?

    prior = CurrentScope::RoleAssignment.find_by(subject: subject)&.role
    assignment = CurrentScope.grant!(subject)
    role = assignment.role
    if prior && prior.id != role.id
      access = role.full_access? ? "full-access " : ""
      warn "WARNING: #{klass}##{subject.id} already held the #{prior.name.inspect} role — " \
           "replacing it with #{access}#{role.name}."
    end
    if role.full_access?
      puts "Granted the full-access #{role.name} role to #{klass}##{subject.id}."
    else
      puts "Assigned the #{role.name} role to #{klass}##{subject.id}. " \
           "That role does not have full access; a host authorizer may independently " \
           "admit this subject."
    end
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

  desc "Summarize would-be denials recorded in report mode: what each subject was refused " \
       "and still needs. It creates no roles. Usage: bin/rails current_scope:report"
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

    # Classifier output. This task prints it. It does not build a second signals
    # hash, and it does not re-run the re-check.
    survey = CurrentScope::DenialSurvey.denials
    if survey.events_table_missing
      # Before any other section. The classifier returned the fact and did not abort.
      abort "The current_scope_events table doesn't exist, so nothing was recorded.\n" \
            "Run: bin/rails current_scope:install:migrations && bin/rails db:migrate"
    end

    rows = survey.rows
    blind_rows = survey.blind_rows
    initiator_rows = survey.initiator_rows
    outstanding = survey.outstanding
    resolved = survey.resolved
    unknown = survey.unknown
    moot = survey.moot
    legacy_model = survey.legacy_model
    dead_model = survey.dead_model
    superseded = survey.superseded
    dead_grants = survey.dead_grants
    untargeted_grants = survey.untargeted_grants
    nonconforming_grants = survey.nonconforming_grants
    unjudgeable_grants = survey.unjudgeable_grants
    preflight = survey.preflight
    preflight_rows = preflight.rows


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
    signals = survey.signals


    # The grouping key has five parts, so one subject and permission can produce
    # two entries (a legacy row and a modern one). The sentences below say
    # "pair(s)", so they count pairs (#196 review).
    resolved_pairs = resolved.map { |denial| [ denial.subject_gid, denial.permission ] }.uniq.count

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
    if outstanding.empty? && unknown.empty? && (resolved.any? || moot.any? || superseded.any?)
      puts
      if moot.any?
        # Two different units in one sentence, so each names its own: resolved
        # counts PAIRS (as the sentence below it always has), moot counts
        # DENIALS (the unit of the headline and of the unknown line).
        puts "  Nothing recorded so far is still outstanding: #{resolved_pairs} subject/permission pair(s)"
        puts "  re-checked against live grants are granted, and #{moot.sum(&:denials)} recorded denial(s) name a"
        puts "  record that no longer loads."
      else
        puts "  Every would-be denial recorded so far is now granted " \
             "(#{resolved_pairs} subject/permission pair(s) re-checked against live grants)."
      end
      puts "  The ledger still lists them because it is append-only. That is the list"
      puts "  you were waiting to see empty; this is what empty looks like."
    end
    if unknown.any?
      puts
      puts "  #{unknown.sum(&:denials)} recorded denial(s) could not be re-checked, because the"
      puts "  subject, the record, the permission or the recorded model no longer resolves."
      puts "  They are counted as OUTSTANDING above: cannot tell is not the same as ready."
      if dead_model.any?
        puts
        puts "  #{dead_model.sum(&:denials)} of those name a model class that no longer loads (renamed or removed)."
        puts "  The gate's own question cannot be put again, so these were asked the only way"
        puts "  left, without a type. An org-wide grant still clears them; a SCOPED one cannot,"
        puts "  because the arm that reads the type is the arm that cannot run. Exercise the"
        puts "  action again in report mode and read the fresh row."
      end
    end
    if moot.any?
      puts
      puts "  #{moot.sum(&:denials)} recorded denial(s) name a record that no longer loads (deleted, or hidden"
      puts "  by a default scope). The gate can never be asked about that record again, so"
      puts "  they are NOT counted as outstanding."
    end
    if superseded.any?
      puts
      puts "  #{superseded.sum(&:denials)} recorded denial(s) predate the stored model and have since been"
      puts "  ASKED AGAIN: a newer row for the same subject, permission and target carried the"
      puts "  gate's model and came back granted. The old row cannot clear itself, because the"
      puts "  ledger is append-only, so it is answered here and left out of the count."
    end
    if legacy_model.any?
      puts
      puts "  #{legacy_model.sum(&:denials)} of the outstanding denial(s) were recorded BEFORE this task stored the"
      puts "  model the gate used, so they were re-checked without one. That is the stricter"
      puts "  question: a subject a scoped grant admits through current_scope_model reads as"
      puts "  denied here. Some of them may be exactly that, and the row is too old to tell."
      puts "  Do not grant on the strength of THIS line. Exercise the action again in report"
      puts "  mode and read the fresh row, or check one by hand with"
      puts "  CurrentScope.resolver.decide(subject:, permission:, record: nil, model: TheModel)."
      puts "  A * in the list below marks a line that INCLUDES one; a marked line can also"
      puts "  hold denials recorded since, which is why the two numbers need not match."
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
    # `mark_keys` is optional and only the would_deny section passes one: a
    # caveat that gives a number and no way to tell which lines it covers leaves
    # the reader to guess, on a list where the wrong guess is a grant (#196
    # review).
    print_permission_counts = lambda do |event_rows, mark: nil|
      subject_gid, mark_keys = mark
      event_rows
        .group_by { |_s, _l, details| details.is_a?(Hash) ? details["permission"] : nil }
        .transform_values(&:count)
        .sort_by { |permission, count| [ -count, permission.to_s ] }
        .each do |permission, count|
          marker = mark_keys&.include?([ subject_gid, permission ]) ? " *" : ""
          puts "    #{count.to_s.rjust(5)}x  #{permission || '(unknown)'}#{marker}"
        end
    end

    # Only the pairs still outstanding, so this list agrees with the headline. A
    # resolved row stays in the ledger forever and printing it here is what made
    # the old survey unreadable: a finished rollout showed a long list under a
    # count of zero. `moot` is left out for the same reason it is left out of the
    # headline: this is the grant-these list and a moot denial cannot be granted.
    # Pinned by "the headline counts only outstanding denials and the moot line
    # counts denials".
    # Keyed on the recorded model too (#196 review), because the grouping above
    # is. A legacy row and a modern row can share a subject, permission and
    # target, land in different buckets (the modern one re-checks with the type
    # and can be resolved), and a four-part key here would match BOTH ledger
    # rows and print a total the headline disagrees with.
    open_keys = (outstanding + unknown).to_set do |denial|
      [ denial.subject_gid, denial.permission, denial.target_gid, denial.record_less, denial.model ]
    end
    open_rows = rows.select do |subject_gid, _label, details, target_gid|
      hash = details.is_a?(Hash) ? details : {}
      open_keys.include?([ subject_gid, hash["permission"], target_gid, hash["record_less"],
                           hash.key?("model") ? hash["model"] : :absent ])
    end

    # One marker for both populations, because they are the same fact: this line
    # holds a denial that was re-checked WITHOUT the model the gate uses. A
    # count with no way to find the lines it refers to is the gap the legacy
    # caveat was given a marker to close, and the dead-model caveat has it too
    # (#196 review).
    no_model_keys = (legacy_model + dead_model).to_set do |denial|
      [ denial.subject_gid, denial.permission ]
    end

    unless open_rows.empty?
      separate.call
      grouped = open_rows.group_by { |subject, _label, _details| subject }

      puts "Would-be denials still outstanding — grant these to stop them (most-denied first):"
      if no_model_keys.any?
        puts "  * = includes denial(s) re-checked WITHOUT the gate's model, because the row"
        puts "      predates it or names a type that no longer loads. See the notes above."
      end
      puts

      grouped.each do |subject_gid, subject_rows|
        label = subject_rows.first[1].presence || subject_gid
        puts "  #{label}#{org_role_suffix.call(subject_gid)}"
        print_permission_counts.call(subject_rows, mark: [ subject_gid, no_model_keys ])
        puts
      end

      puts "Total: #{open_rows.count} outstanding would-be denial(s) across " \
           "#{grouped.size} subject(s)."
      if resolved.any?
        puts "#{resolved_pairs} more subject/permission pair(s) were recorded and are " \
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

    if unjudgeable_grants > 1
      warn "[CurrentScope] #{unjudgeable_grants - 1} more grant(s) could not be judged " \
           "against their type's declaration; all are reported as conforming."
    end

    unless nonconforming_grants.empty?
      separate.call
      puts "Scoped grants their type no longer accepts (#183):"
      puts
      nonconforming_grants.each { |grant| puts grant_line.call(grant) }
      puts
      puts "  These rows were written before their type declared its grantable"
      puts "  roles, or before that declaration changed. The check runs on write,"
      puts "  so they still resolve. Revoke the ones that should not stand."
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
    rescue CurrentScope::DefinitionsDocument::Error, CurrentScope::ConfigurationError,
           ActiveRecord::RecordInvalid => e
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
