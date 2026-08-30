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
    def self.check!(allow_database_task: true)
      return if allow_database_task && running_a_database_task?
      # Escape hatch for tooling that must BOOT in order to migrate — our own
      # bin/db does exactly that, because a schema.rb DUMPED FROM PostgreSQL or
      # SQLite carries no collation, so loading it on MySQL leaves the grant
      # columns case insensitive (#194; a dump taken from MySQL does carry a
      # per-column collation, which is the half the old wording had wrong). Deliberately an explicit opt-out and not a config flag: a host
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

      if info.type.in?([ :string, :text ])
        # STRING IS NOT ENOUGH — the width has to be right too. A varchar(32)
        # passes "is it a string?" and then truncates every UUID written to it,
        # which is the original collision with a different cause. A text column
        # is unbounded and therefore wide enough.
        if !info.limit.nil? && info.limit < CurrentScope::KEY_LIMIT
          raise ConfigurationError,
                "#{column_label(model, column)} holds #{info.limit} characters; CurrentScope " \
                "needs #{CurrentScope::KEY_LIMIT}. A UUID is 36 and a narrower column would " \
                "truncate it, so two keys sharing a prefix would name one record (#151). Run " \
                "`#{env_prefix}bin/rails current_scope:repair_schema` to widen it."
        end

        if info.respond_to?(:null) && info.null
          raise ConfigurationError,
                "#{column_label(model, column)} allows NULL, so a grant may fail to name " \
                "one record. Run `#{env_prefix}bin/rails current_scope:repair_schema` to " \
                "restore the required NOT NULL constraint (#151)."
        end

        check_collation!(model, column) if mysql?
        return
      end

      # THREE paths, because this refusal has three audiences and each needs
      # the others' command to be wrong for them (#193 review).
      #
      # NOT INSTALLED: the host has upgraded the gem and never run
      # install:migrations. That pair copies the migration into db/migrate,
      # stamps it, and dumps schema.rb, so CI and every teammate get the shape
      # too. repair_schema alone would change the live columns and leave
      # schema.rb declaring an integer, which rebuilds the pre-#151 shape on the
      # next db:schema:load.
      #
      # INSTALLED, NOT YET RUN HERE: a production or staging server that got the
      # migration in a deploy and has not migrated. Plain db:migrate against
      # THAT database, and nothing else: repair_schema would widen the columns
      # while writing no schema_migrations row, so db:abort_if_pending_migrations
      # then fails for a second, unrelated reason.
      #
      # BUILT FROM schema.rb: a test database, a fresh checkout, CI. Every
      # version is stamped already, so db:migrate finds nothing pending and
      # prints nothing. repair_schema re-applies the widening directly and is
      # idempotent. That is the case the #116 bake hit, one command after
      # migrating development successfully.
      raise ConfigurationError,
            "#{column_label(model, column)} is still #{info.type}. CurrentScope stores a " \
            "record's primary key there, and an integer column silently truncates a " \
            "UUID — two subjects collapse into one identity and one inherits the " \
            "other's roles (#151). Which command depends on where this database came " \
            "from. If the widening migration is not in db/migrate yet, run " \
            "`bin/rails current_scope:install:migrations && bin/rails db:migrate` in your " \
            "development checkout, then commit the migration and deploy it: that path also " \
            "updates schema.rb, so CI and your teammates and this server all get the same " \
            "shape. No RAILS_ENV on that one, because it is about your checkout and not " \
            "about this database. If it is installed but has not run here, run " \
            "`#{env_prefix}bin/rails db:migrate`. If this database was BUILT from " \
            "schema.rb, every version is stamped and db:migrate has nothing pending: run " \
            "`#{env_prefix}bin/rails current_scope:repair_schema`."
    end

    # Collation matters as much as type on MySQL: its default is case AND accent
    # insensitive, so "ABC" and "abc" — or "jose" and "josé" — are the same
    # record. A database built from schema.rb has the right column type and the
    # wrong collation, which is the common case for a new app and for CI.
    def self.check_collation!(model, column)
      info = model.columns_hash[column]
      return if info.nil?

      # A security guard must not fail open. The column exists and we are on
      # MySQL, so its collation should always be readable; if it is not, refuse
      # rather than bless a column we cannot prove compares case-sensitively —
      # the same fatal treatment roles_controller#candidate_key_as_text now gives
      # missing collation.
      if info.collation.nil?
        raise ConfigurationError,
              "#{column_label(model, column)} has a MySQL collation that could not be read, " \
              "so CurrentScope cannot prove \"ABC\" and \"abc\" are different records " \
              "(#151). Run `#{env_prefix}bin/rails current_scope:repair_schema`."
      end

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
            "[CurrentScope] #{column_label(model, column)} uses #{info.collation}, which is " \
            "case-sensitive but PAD SPACE — a key with a trailing space would still " \
            "match one without. On MySQL 8.0.17+ run " \
            "`#{env_prefix}bin/rails current_scope:repair_schema` to move to " \
            "utf8mb4_0900_bin (#151)."
          )
        end
        return
      end

      # NOT db:migrate. A database loaded from schema.rb has every migration
      # version already stamped, so db:migrate finds nothing pending and prints
      # nothing while the collation stays wrong. Whether the collation IS wrong
      # depends on where that schema.rb was dumped: a dump from MySQL carries a
      # per-column collation, one from PostgreSQL or SQLite carries none (#194).
      # A team that develops on one adapter and runs MySQL in CI is the case
      # that lands here, and naming db:migrate sent them to a command that could
      # not work.
      raise ConfigurationError,
            "#{column_label(model, column)} uses the #{info.collation} collation, which " \
            "is case and accent insensitive — \"ABC\" and \"abc\" would be the same " \
            "record, so a grant on one reaches the other (#151). Run " \
            "`#{env_prefix}bin/rails current_scope:repair_schema` to apply a binary collation " \
            "(idempotent, and it works on a schema-loaded database where db:migrate " \
            "has nothing pending)."
    end

    # WHICH DATABASE THIS REFUSED, and how to name it on a command line (#193).
    #
    # Every refusal below prescribes a command, and a command with no
    # environment runs against development. That built a loop the #116 bake
    # walked straight into: a host migrates development, the next `bin/rails
    # test` aborts because the TEST database still has the old shape, and the
    # message tells them to run the command they have just run. Nothing on
    # screen distinguished the database that failed from the one they repaired.
    #
    # The connection asked is the JUDGED MODEL'S, not ActiveRecord::Base's and
    # not RoleAssignment's: the guard reads columns from more than one model, and
    # a host that puts them on more than one database has to be told which of
    # them failed (#193 review).
    # connection_pool, not connection: `model.connection` leases one, which
    # Rails 8.1 soft-deprecates and refuses outright where permanent checkout is
    # disallowed. The rescue below would then swallow that and drop the database
    # name — losing the fact this exists to add, on the hosts most likely to
    # have tuned their pool (#193 review).
    def self.database_context(model)
      name = model.connection_pool.db_config.database
      "the #{Rails.env} database #{name.inspect}"
    rescue StandardError
      # The message is the whole product at this moment, so a database whose
      # name cannot be read must still produce a refusal that names the
      # environment. Never let the diagnostic take the guard down with it.
      "the #{Rails.env} database"
    end

    # The prefix only where it changes something. Printing `RAILS_ENV=development`
    # would teach the reader to type a word that does nothing, and the next time
    # they see the prefix they would ignore it.
    def self.env_prefix
      Rails.env.development? ? "" : "RAILS_ENV=#{Rails.env} "
    end

    def self.column_label(model, column)
      "#{model.table_name}.#{column} on #{database_context(model)}"
    end

    # The GRANT tables' connection, not ActiveRecord::Base's. The columns being
    # judged come from RoleAssignment.columns_hash, so the adapter question has
    # to be asked of the same database those columns live in — a host that puts
    # the engine's tables on a second connection would otherwise be judged by the
    # wrong server's collation rules.
    def self.mysql?
      config = CurrentScope::RoleAssignment.connection_pool.db_config
      # BOTH names, ORed, and that is fail-closed on purpose (#194 review).
      # `CurrentScope.mysql?` elsewhere reads the adapter CLASS name, while a
      # db_config knows the key from database.yml. They agree for every common
      # adapter, and where they could not, the cost of disagreeing is a skipped
      # collation check — silent, with the #151 case-folding escalation left
      # live. So ask for both and treat either as yes.
      class_name = begin
        config.adapter_class.name
      rescue StandardError
        nil
      end
      CurrentScope.mysql_adapter?(config.adapter) || CurrentScope.mysql_adapter?(class_name)
    end

    # Rake tasks that may BOOT even against an unrepaired schema.
    #
    # The check raises from after_initialize, which every Rails command runs —
    # including `current_scope:repair_schema` and `db:migrate`, the commands its
    # own refusals tell the host to run. Without an exemption an upgrading host
    # is stuck: the app refuses to boot and the repair refuses to run, for the
    # same reason. `assets:` is the
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
      current_scope:identity:check
    ].freeze

    # Namespaces whose children are all schema tooling (db:migrate:up,
    # db:schema:load, assets:precompile, …).
    #
    # `current_scope:identity:` is NOT here, and the omission is the point.
    # Only `identity:check` is exempt, named individually above: it reads the
    # HOST's subject table and touches no grant column, so it is safe on an
    # unrepaired schema. `identity:setup WRITE=1` calls CurrentScope.grant!,
    # which writes RoleAssignment rows — and grant! does not re-check the
    # schema, because the check runs once at boot. Exempting the namespace
    # would let the one #158 task that WRITES grants do so on exactly the
    # pre-#151 columns that collapse two subjects into one. An operator on an
    # unrepaired schema is told to run current_scope:repair_schema first, which
    # is exempt and is the fix.
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
      return false if tasks.empty?

      # EVERY task, not any task. Rake takes a LIST — `bin/rails db:migrate
      # db:import_users` is one invocation, one boot, two tasks — so asking
      # "is one of these exempt?" let a single exempt name carry every task
      # beside it past the #151 guard. `current_scope:identity:check` is
      # read-only and exempt; `current_scope:identity:setup` writes grants and
      # is deliberately not. Chained, `any?` exempted the writer through its
      # own sibling, which is precisely the hole listing them separately was
      # meant to close. It also defeated the exact-name rule two lists up: the
      # host task `db:import_users` is refused alone and was exempted when run
      # after `db:migrate`.
      #
      # An exemption is a claim about what the whole command does. One
      # non-exempt task makes the command non-exempt.
      tasks.all? do |task|
        BOOT_EXEMPT_TASKS.include?(task) || task.start_with?(*BOOT_EXEMPT_NAMESPACES)
      end
    rescue StandardError
      # No rake application in scope (a server or console): not a database task.
      false
    end
    private_class_method :check_id_column!, :check_collation!, :mysql?,
                         :database_context, :env_prefix, :column_label
    # Public: Engine#validate_subject_key! asks the same "may this command boot
    # without the schema?" question and reuses this rather than re-deriving it.
    public_class_method :running_a_database_task?
  end
end
