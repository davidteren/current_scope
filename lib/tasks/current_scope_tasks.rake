namespace :current_scope do
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
