module CurrentScope
  # Formats the buckets the report task already gathered.
  # It does not classify denials, and it does not scan grants.
  class ReportPrinter
    def initialize(**buckets)
      @buckets = buckets
    end

    def to_s
      @out = +""
      rows = @buckets.fetch(:rows)
      blind_rows = @buckets.fetch(:blind_rows)
      initiator_rows = @buckets.fetch(:initiator_rows)
      preflight = @buckets.fetch(:preflight)
      preflight_rows = @buckets.fetch(:preflight_rows)
      outstanding = @buckets.fetch(:outstanding)
      resolved = @buckets.fetch(:resolved)
      unknown = @buckets.fetch(:unknown)
      moot = @buckets.fetch(:moot)
      legacy_model = @buckets.fetch(:legacy_model)
      dead_model = @buckets.fetch(:dead_model)
      superseded = @buckets.fetch(:superseded)
      dead_grants = @buckets.fetch(:dead_grants)
      untargeted_grants = @buckets.fetch(:untargeted_grants)
      nonconforming_grants = @buckets.fetch(:nonconforming_grants)
      unjudgeable_grants = @buckets.fetch(:unjudgeable_grants)
      # The subject's current org-wide role, when resolvable. The grid reads
      # differently if someone already holds a role that just doesn't tick these
      # keys. Best-effort: one deleted subject must not abort the rest of the report.
      org_role_suffix = lambda do |subject_gid|
        subject = GlobalID::Locator.locate(subject_gid)
        role = subject && CurrentScope::RoleAssignment.find_by(subject: subject)&.role
        role ? " — currently #{role.name}" : ""
      rescue StandardError
        ""
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
          outstanding.sum(&:denials) + unknown.sum(&:denials),
        "scoped grants that can never match" => dead_grants.count,
        "scoped grants worth checking" => untargeted_grants.count,
        "scoped grants their type no longer accepts" => nonconforming_grants.count,
        "SoD actions that will RAISE (500, not grantable)" => preflight_rows.count,
        "SoD blind-spot denials (not grantable)" => blind_rows.count,
        "SoD actions that already RAISED (500, not grantable)" => initiator_rows.count
      }.reject { |_label, count| count.zero? }

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
      @out
    end

    private

    # Same record shape as Kernel#puts, written into the returned string.
    # The rake task prints that string once.
    def puts(*args)
      args = [ nil ] if args.empty?

      args.each do |arg|
        text = arg.nil? ? "" : arg.to_s
        @out << text
        @out << "\n" unless text.end_with?("\n")
      end
    end
  end
end
