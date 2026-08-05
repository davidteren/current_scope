module CurrentScope
  # The #151 boot guard: does this database actually have the grant-column shape
  # the fix requires, and may THIS command boot without it?
  #
  # Its own file rather than more of Engine, matching SodPreflight and
  # ParentChain — Engine states when a check runs, the check itself lives here.
  #
  # #151 is fixed by a MIGRATION, and a gem upgrade does not run one. A host that
  # bundles 0.5 and deploys without applying it keeps integer id columns and
  # keeps the full escalation, silently, because every code path behaves
  # correctly against whatever schema it is given. So check the schema itself and
  # refuse to serve. This is the one check that cannot be a validation: the
  # damage is in the column, not in the next write.
  module SchemaGuard
    def self.check!
      return if running_a_database_task?
      # Escape hatch for tooling that must BOOT in order to migrate — our own
      # bin/db does exactly that, because schema.rb cannot carry a MySQL
      # collation. Deliberately an explicit opt-out and not a config flag: a host
      # that sets this in production has chosen to run without the check.
      return if ENV["CURRENT_SCOPE_SKIP_SCHEMA_CHECK"] == "1"

      # Strict "1" on purpose — this switches OFF a security control, so it
      # should be awkward to trip. But silence would be worse than strictness: a
      # host who writes `=true` (which the gem's other env opt-out does accept)
      # would otherwise believe the check was off while it was still armed.
      if ENV.key?("CURRENT_SCOPE_SKIP_SCHEMA_CHECK")
        Rails.logger&.warn(
          "[CurrentScope] CURRENT_SCOPE_SKIP_SCHEMA_CHECK is set to " \
          "#{ENV['CURRENT_SCOPE_SKIP_SCHEMA_CHECK'].inspect} and was IGNORED — the only " \
          "value that disables the #151 schema check is the string \"1\"."
        )
      end

      # BOTH halves of every grant predicate, not just the ids. The migration
      # widens the id columns and then re-collates the type columns, and MySQL
      # auto-commits each statement — so a migration that dies between the two
      # leaves binary ids beside case-insensitive types, permanently. Checking
      # only the ids blesses exactly that state, and a grant on `Widget#5` then
      # matches a check for `WIDGET#5`. Same escalation, other column.
      {
        CurrentScope::RoleAssignment => { ids: %w[subject_id], types: %w[subject_type] },
        CurrentScope::ScopedRoleAssignment => {
          ids: %w[subject_id resource_id], types: %w[subject_type resource_type]
        }
      }.each do |model, groups|
        next unless model.table_exists?

        groups[:ids].each { |column| check_id_column!(model, column) }
        # Type columns are varchar already; only their collation can be wrong.
        groups[:types].each { |column| check_collation!(model, column) } if mysql?
      end
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
      # There is genuinely no database yet (a fresh checkout running db:create,
      # a build step with no server). Nothing to judge, so stay quiet.
      #
      # Narrow ON PURPOSE. Rescuing ActiveRecordError broadly here would turn any
      # transient error into a silent all-clear, which is a security guard
      # failing open. Anything else propagates.
      nil
    end

    def self.check_id_column!(model, column)
      info = model.columns_hash[column]
      return if info.nil?

      if info.type == :string
        # STRING IS NOT ENOUGH — the width has to be right too. A varchar(32)
        # passes "is it a string?" and then truncates every UUID written to it,
        # which is the original collision with a different cause. limit is nil on
        # an unbounded text column, which holds any key and is fine.
        if !info.limit.nil? && info.limit < CurrentScope::KEY_LIMIT
          raise ConfigurationError,
                "#{model.table_name}.#{column} holds #{info.limit} characters; CurrentScope " \
                "needs #{CurrentScope::KEY_LIMIT}. A UUID is 36 and a narrower column would " \
                "truncate it, so two keys sharing a prefix would name one record (#151). Run " \
                "`bin/rails current_scope:repair_schema` to widen it."
        end

        check_collation!(model, column) if mysql?
        return
      end

      raise ConfigurationError,
            "#{model.table_name}.#{column} is still #{info.type}. CurrentScope stores a " \
            "record's primary key there, and an integer column silently truncates a " \
            "UUID — two subjects collapse into one identity and one inherits the " \
            "other's roles (#151). Run `bin/rails current_scope:install:migrations && " \
            "bin/rails db:migrate` to widen it."
    end

    # Collation matters as much as type on MySQL: its default is case AND accent
    # insensitive, so "ABC" and "abc" — or "jose" and "josé" — are the same
    # record. A database built from schema.rb has the right column type and the
    # wrong collation, which is the common case for a new app and for CI.
    def self.check_collation!(model, column)
      info = model.columns_hash[column]
      return if info.nil? || info.collation.nil?

      if info.collation.end_with?("_bin")
        # Binary, but not necessarily NO PAD. utf8mb4_bin is PAD SPACE, so it
        # still compares "abc" equal to "abc " — a narrower relative of the same
        # collision. The migration prefers utf8mb4_0900_bin for that reason and
        # falls back only where the server (MySQL < 8.0.17) offers nothing
        # better. Refusing to boot there would strand a host on a shortcoming
        # they cannot fix, so say it plainly once instead.
        # Every _bin collation EXCEPT the 0900 family is PAD SPACE, not just
        # utf8mb4_bin — latin1_bin and friends fold trailing spaces too.
        unless info.collation.start_with?("utf8mb4_0900")
          Rails.logger&.warn(
            "[CurrentScope] #{model.table_name}.#{column} uses #{info.collation}, which is " \
            "case-sensitive but PAD SPACE — a key with a trailing space would still " \
            "match one without. On MySQL 8.0.17+ run " \
            "`bin/rails current_scope:repair_schema` to move to utf8mb4_0900_bin (#151)."
          )
        end
        return
      end

      # NOT db:migrate. A database loaded from schema.rb has every migration
      # version already stamped, so db:migrate finds nothing pending and prints
      # nothing while the collation stays wrong — and schema.rb cannot carry a
      # MySQL collation, so that is the normal state of a new app and of CI.
      # Naming db:migrate here sent hosts to a command that could not work.
      raise ConfigurationError,
            "#{model.table_name}.#{column} uses the #{info.collation} collation, which " \
            "is case and accent insensitive — \"ABC\" and \"abc\" would be the same " \
            "record, so a grant on one reaches the other (#151). Run " \
            "`bin/rails current_scope:repair_schema` to apply a binary collation " \
            "(idempotent, and it works on a schema-loaded database where db:migrate " \
            "has nothing pending)."
    end

    # The GRANT tables' connection, not ActiveRecord::Base's. The columns being
    # judged come from RoleAssignment.columns_hash, so the adapter question has
    # to be asked of the same database those columns live in — a host that puts
    # the engine's tables on a second connection would otherwise be judged by the
    # wrong server's collation rules.
    def self.mysql?
      CurrentScope.mysql?(CurrentScope::RoleAssignment.connection)
    end

    # Rake tasks that may BOOT even against an unrepaired schema.
    #
    # The check raises from after_initialize, which every Rails command runs —
    # including `db:migrate`, the command its own error message tells the host to
    # run. Without an exemption an upgrading host is stuck: the app refuses to
    # boot and the repair refuses to run, for the same reason. `assets:` is the
    # same trap one step less obvious — a deploy pipeline that precompiles before
    # migrating dies before it ever reaches the fix.
    #
    # EXACT NAMES, not prefixes, and that distinction is load-bearing: matching
    # `db:create` as a prefix also matches a host's `db:create_tenant`, and
    # `db:migrate` matches `db:migrate_legacy_users`. Prefix matching turned an
    # allow list back into the `db:` free-for-all it replaced. Namespaces that
    # legitimately have children are listed separately, ending in a colon.
    #
    # Anything that serves traffic or runs host code — server, console, runner —
    # is deliberately absent. db:setup, db:reset and db:prepare are present
    # despite seeding: they are how a host REBUILDS a database, and refusing them
    # would leave a broken schema with no way to replace it.
    BOOT_EXEMPT_TASKS = %w[
      db:create db:drop db:migrate db:rollback db:version db:prepare db:setup
      db:reset db:abort_if_pending_migrations db:_dump
      current_scope:install current_scope:repair_schema
    ].freeze

    # Namespaces whose children are all schema tooling (db:migrate:up,
    # db:schema:load, assets:precompile, …).
    BOOT_EXEMPT_NAMESPACES = %w[
      db:migrate: db:schema: db:structure: db:test: db:environment:
      current_scope:install: assets:
    ].freeze

    # …minus these, which the lists above would otherwise cover. A bare `db:seed`
    # repairs nothing and runs host code, and seeds routinely create grants
    # through this engine — on the pre-migration schema, exactly the writes that
    # collapse two subjects into one. Prefixes here on purpose: db:seed:replant
    # (which Rails ships) and a host's own db:seed_users are both host code, and
    # over-refusing is the safe direction for a deny list.
    BOOT_REFUSED_TASKS = %w[db:seed db:fixtures:].freeze

    def self.running_a_database_task?
      return false unless defined?(Rake) && Rake.respond_to?(:application)

      # `app:` is how an engine's host tasks are namespaced from inside the
      # engine (rails/tasks/engine.rake), so strip it once here instead of
      # spelling every entry twice in both lists.
      tasks = Rake.application.top_level_tasks.map { |task| task.delete_prefix("app:") }
      return false if tasks.any? { |task| task.start_with?(*BOOT_REFUSED_TASKS) }

      tasks.any? do |task|
        BOOT_EXEMPT_TASKS.include?(task) || task.start_with?(*BOOT_EXEMPT_NAMESPACES)
      end
    rescue StandardError
      # No rake application in scope (a server or console): not a database task.
      false
    end
    private_class_method :check_id_column!, :check_collation!, :mysql?,
                         :running_a_database_task?
  end
end
