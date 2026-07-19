module CurrentScope
  # Append-only authorization event ledger. Design rules:
  #
  #   - Append-only: there is no updated_at; persisted rows are never mutated.
  #   - Identities and target are stored as GlobalID strings, alongside a
  #     denormalized `target_label`, so the history outlives the records it
  #     names (a deleted role still renders in the ledger).
  #   - `actor` and `subject` are ALWAYS present. subject == actor unless
  #     impersonating; impersonated rows are exactly the ones where
  #     subject <> actor.
  #   - NORMATIVE target mapping: assignment events (org_role.*, scoped_role.*)
  #     target the GRANTEE (the subject being granted); role.* events target the
  #     role. Role/resource ride in `details`.
  #
  # The AR-level `readonly?` ceiling is honest but NOT total. These BYPASS it:
  #   update_all / delete_all / update_column(s) / insert_all / raw SQL.
  # The sandbox reset job (a later unit) is the one sanctioned `delete_all`
  # caller. DB-level hardening is adapter-honest: REVOKE UPDATE/DELETE covers
  # PostgreSQL and MySQL hosts; SQLite hosts get file permissions only.
  # Hash-chain tamper-evidence is deferred.
  class Event < ApplicationRecord
    # Once written, a row is immutable — blocks update / save / destroy at the
    # AR layer. See the class header for the operations that bypass this.
    def readonly? = persisted?

    class << self
      # The ONE recording entry point. Reads the ambient actor/subject from
      # CurrentScope::Current, serializes actor/subject/target as GlobalID
      # strings, denormalizes a human label for the target, and — when
      # config.audit is on — appends exactly one row.
      #
      #   CurrentScope::Event.record!(event: "role.created", target: role,
      #                               details: { name: "Owner" })
      #
      # Raises ConfigurationError (loud, matching the SoD posture) when there is
      # no ambient actor and no explicit actor: override. Silent no-op (returns
      # nil) when config.audit is false.
      #
      # Optional actor:/subject: overrides (#30): when non-nil they replace the
      # ambient reads so bootstrap paths (grant!, rake, seeds) can self-attribute
      # without a controller. Omit both for byte-for-byte ambient behavior.
      # Pin BOTH on a self-attributed grant so an ambient Current.user cannot
      # leak into subject and mis-record the row as impersonation.
      def record!(event:, target:, details: nil, actor: nil, subject: nil)
        return unless CurrentScope.config.audit

        actor ||= CurrentScope::Current.actor
        if actor.nil?
          raise CurrentScope::ConfigurationError,
                "CurrentScope::Event.record! has no actor — CurrentScope::Current.actor is nil. " \
                "Set the ambient context (the controller hook, or with_current_user in tests) before recording."
        end

        # Explicit subject wins; else Current.user; else actor (never nil when
        # actor is set, equals actor when not impersonating).
        subject ||= CurrentScope::Current.user || actor

        # requires_new: on PostgreSQL a StatementInvalid aborts the *whole*
        # open transaction even if rescued — so a missing events table would
        # poison grant!/controller mutation transactions that wrap record!.
        # A savepoint isolates the audit write: default audit=true degrades
        # and the assignment commits; :strict re-raises and rolls the outer
        # mutation back (PR #102 review).
        Event.transaction(requires_new: true) do
          create!(
            event: event.to_s,
            actor: actor.to_gid.to_s,
            subject: subject.to_gid.to_s,
            target: target.to_gid.to_s,
            target_label: label_for(target),
            details: details,
            request_id: CurrentScope::Current.request_id
          )
        end
      rescue ActiveRecord::StatementInvalid => e
        raise unless missing_events_table?(e)

        # :strict — an audit-mandatory host refuses to commit a mutation with no
        # audit row. Re-raise so the enclosing (mutation-wrapping) transaction
        # rolls back rather than silently degrading. Checked as `== :strict`, not
        # `!= true`, so the tri-state can't be flattened by a future refactor.
        # (Impersonation-boundary events have no DB mutation to roll back, so a
        # raise there is simply a loud 500 on a mis-migrated host.)
        raise if CurrentScope.config.audit == :strict

        # true (default) — an existing host that upgrades the gem without running
        # the new migration must not break on its first mutation. Degrade
        # gracefully: skip recording and warn once (not on every call), naming
        # the fix. A host that wants audit runs the migration; one that doesn't
        # can set config.audit = false to silence it, or :strict to fail loud.
        warn_missing_events_table_once
        nil
      end

      private

      def warn_missing_events_table_once
        return if @missing_events_table_warned

        @missing_events_table_warned = true
        Rails.logger&.warn(
          "[CurrentScope] audit is on but the current_scope_events table is missing — " \
          "skipping audit recording. Run `rails current_scope:install:migrations` and " \
          "migrate to enable it, or set `CurrentScope.config.audit = false` to silence this."
        )
      end

      # The shared chain (CurrentScope.label_for) — the same label the UI
      # renders is the one denormalized into target_label, so the ledger and
      # the screen can't disagree about what a record was called.
      def label_for(record)
        CurrentScope.label_for(record)
      end

      # Recognizes "table is missing" across adapters and Rails' own schema
      # reflection: SQLite ("no such table" / "Could not find table"),
      # PostgreSQL ("relation ... does not exist"), MySQL ("Unknown table" /
      # "doesn't exist"). The `column` exclusion keeps a missing-COLUMN error
      # (e.g. "column ... of relation current_scope_events does not exist" after
      # a partial migration) from being misreported as a missing table, which
      # would point operators at the wrong fix.
      def missing_events_table?(error)
        message = error.message
        message.include?("current_scope_events") &&
          !message.match?(/\bcolumn\b/i) &&
          message.match?(/no such table|could not find table|does(?:n't| not) exist|unknown table|undefined table/i)
      end
      # PUBLIC: report mode's ledger warning asks this too (#37). It is one
      # question — "is this the un-migrated-table case?" — and one adapter-shaped
      # answer, so it gets one definition. A second opinion elsewhere is a second
      # opinion that drifts, and this one decides which fix an operator is sent
      # after. (#59 review)
      public :missing_events_table?
    end
  end
end
