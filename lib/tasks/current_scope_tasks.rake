namespace :current_scope do
  desc "Grant the full-access Owner role to a subject (bootstrap the first admin). " \
       "Usage: bin/rails current_scope:grant SUBJECT_ID=1"
  task grant: :environment do
    id = ENV["SUBJECT_ID"]
    abort "SUBJECT_ID is required, e.g. bin/rails current_scope:grant SUBJECT_ID=1" if id.blank?

    klass = CurrentScope.config.subject_class.constantize
    subject = klass.find_by(id: id)
    abort "No #{klass} with id=#{id}" if subject.nil?

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
    rescue ActiveRecord::StatementInvalid => e
      # Report mode without the migration records nothing (the ledger degrades and
      # warns once). Reaching for this summary is exactly how a host discovers
      # that, so it must name the fix rather than raise a stack trace at them.
      raise unless e.message.match?(/current_scope_events/i)

      abort "The current_scope_events table doesn't exist, so nothing was recorded.\n" \
            "Run: bin/rails current_scope:install:migrations && bin/rails db:migrate"
    end

    if rows.empty?
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
      next
    end

    # ponytail: group in Ruby, not SQL. `details` is a JSON column and querying
    # into it is adapter-specific; this is a rollout aid run by hand over a
    # transitional table, so portability beats a smarter query.
    grouped = rows.group_by { |subject, _label, _details| subject }

    puts "Would-be denials — grant these to stop them (most-denied first):"
    puts

    grouped.each do |subject_gid, subject_rows|
      label = subject_rows.first[1].presence || subject_gid
      puts "  #{label}#{org_role_suffix.call(subject_gid)}"

      subject_rows
        .group_by { |_s, _l, details| details.is_a?(Hash) ? details["permission"] : nil }
        .transform_values(&:count)
        .sort_by { |permission, count| [ -count, permission.to_s ] }
        .each { |permission, count| puts "    #{count.to_s.rjust(5)}x  #{permission || '(unknown)'}" }

      puts
    end

    puts "Total: #{rows.count} would-be denials across #{grouped.size} subject(s)."
  end
end
