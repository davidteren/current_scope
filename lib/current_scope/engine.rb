module CurrentScope
  class Engine < ::Rails::Engine
    isolate_namespace CurrentScope

    # An AccessDenied that escapes any Guard rescue (PORO, Context-only
    # controller, re-raise) must 403, not 500. Never turns a deny into an
    # allow — the exception already blocked the action (#39).
    #
    # ||= so a host that already set this mapping (e.g. :not_found to hide
    # existence) in config/application.rb is not clobbered. before:
    # action_dispatch.configure so ExceptionWrapper.rescue_responses picks the
    # entry up when it merge!s the config hash.
    initializer "current_scope.rescue_responses", before: "action_dispatch.configure" do |app|
      app.config.action_dispatch.rescue_responses["CurrentScope::AccessDenied"] ||= :forbidden
    end

    # Belt for Rails upgrades: if action_dispatch.configure is renamed/reordered
    # and the config merge is missed, still pin the class map. Use key? — the
    # ExceptionWrapper hash defaults missing keys to :internal_server_error
    # (truthy), so ||= would never write.
    initializer "current_scope.rescue_responses_apply", after: "action_dispatch.configure" do
      map = ActionDispatch::ExceptionWrapper.rescue_responses
      map["CurrentScope::AccessDenied"] = :forbidden unless map.key?("CurrentScope::AccessDenied")
    end

    # The `current_scope_parent` declaration (#108). on_load rather than a
    # host-included concern: it is an acts_as_*-style class macro, and hanging it
    # off CurrentScope::Scopeable would both contradict that module's BROWSE-ONLY
    # contract and register every parent-declaring model in the scoped-role
    # picker as a side effect. instance_accessor: false because the declaration is
    # a class-level fact and is only ever read through the class; an instance
    # reader would blur that. (It does NOT collide with the method-form mistake
    # ParentChain.reject_method_form! catches — that one is named
    # current_scope_parent, a different method entirely.)
    initializer "current_scope.parent_chain" do
      ActiveSupport.on_load(:active_record) do
        class_attribute :current_scope_parent_association,
                        instance_accessor: false,
                        default: nil
        extend CurrentScope::ParentChain::Declaration
      end
    end

    # Cross-field config invariants (e.g. bypass permission ∉ sod_actions) must
    # run AFTER the host initializer has assigned every field — a writer on
    # either attr alone is order-dependent. once, not on to_prepare (config
    # does not change on code reload). #40.
    config.after_initialize do
      CurrentScope.config.validate!
      # Two separate checks, called separately so each raises under its own name.
      # The schema guard inspects four columns across both grant tables and can
      # refuse over `resource_type`'s collation — a message that read very oddly
      # coming out of something called validate_subject_key!.
      CurrentScope::Engine.grant_columns_widened!
      CurrentScope::Engine.validate_subject_key!
    end

    # Routes (and therefore the derived permission catalog) can change on
    # every code reload in development, and reloaded host models must re-register
    # as scopeable rather than pile up stale/duplicate entries. Both reset here,
    # ahead of eager-load, so the registry rebuilds cleanly.
    config.to_prepare do
      CurrentScope.reset_catalog!
      CurrentScope.reset_scopeable_registry!
      # The cross-controller nudge warns once per site; a reload can change what's
      # routed, so a stale latch would hide a divergence the edit just created.
      CurrentScope.reset_cross_controller_warnings!
      # Same reason for the tripwire's :warn latch: a reload can change whether a
      # controller#action is gated, and a stale latch would hand a dev running
      # :warn a false all-clear right after the edit.
      CurrentScope::GatingTripwire.reset_warnings!
      # Same reason: a reload can change a declared chain, and a latched
      # truncation warning would hide the one the edit just created.
      CurrentScope::ParentChain.reset_warnings!
      # Declaration validation that needs reflection.klass runs HERE, not on the
      # request path, so a bad declaration is caught before traffic. This pass is
      # the DEVELOPMENT one: to_prepare runs before :eager_load!, so it sees only
      # models something else already loaded — but it re-runs on every reload, so
      # a dev's coverage grows as they work. The authoritative pass is the
      # eager-load one below. (#139)
      CurrentScope::ParentChain.validate_declarations!
    end

    # #139: the pass that sees every declaring model that was eager-loaded.
    #
    # Railties runs :run_prepare_callbacks (the to_prepare above) BEFORE
    # :eager_load!, with the source comment "This needs to happen before eager
    # load so it happens in exactly the same point regardless of
    # config.eager_load". So that pass reads a registry holding only whatever
    # was already loaded — in production, close to nothing — and the ONE check
    # it performs could be skipped entirely for a model nobody had touched yet.
    #
    # That check is not cosmetic. validate_key! is the only guard anywhere
    # against a current_scope_parent on a belongs_to with a custom
    # `primary_key:`, and nothing on the request path repeats it. Unvalidated,
    # both scope_for and the unloaded load_parent walk key the parent on its
    # primary key — comparing values from different columns. Both hide records
    # the grant should reach AND surface / open unrelated ones whose
    # foreign-key value happens to collide with a granted parent's id. With a
    # numeric custom key that collision space is dense. See the
    # characterization test in test/parent_chain_test.rb.
    #
    # Gated on eager_load, which is the whole point: where it is on, declaring
    # models that were eager-loaded are already in the registry, so this pass
    # does not walk the autoloader looking for *new* declarers. Where it is off
    # (development), the registry is partial anyway and running this would
    # safe_constantize reloadable names during initialization — the thing Rails
    # tells you not to do, and which pins constants that the first reload then
    # makes stale. Development keeps the to_prepare pass, which re-runs and
    # catches up.
    #
    # Residual autoload of association TARGETS still exists: validate_key!
    # resolves reflection.klass, so a parent model kept off the eager-load
    # surface can load on first validation. That is the same partial-coverage
    # bargain as do_not_eager_load for declaring models, and it is named in
    # UPGRADING.md rather than implied away by "nothing here autoloads".
    #
    # after_initialize (not after: :eager_load!) so we sit in the same finisher
    # window as other boot checks. Order among after_initialize blocks is
    # registration order: a host that first loads a declaring model from a
    # *later* after_initialize still misses this pass — same residual family,
    # documented in UPGRADING.md.
    config.after_initialize do |app|
      CurrentScope::ParentChain.validate_declarations! if app.config.eager_load
    end

    # #133: a deploy must not boot green and 500 on the first gated request. An
    # SoD action whose model defines no current_scope_initiator raises per
    # request — in :report mode too, which is where it hurts most, because
    # report mode is what a host turns on to survey live traffic without
    # changing anything for users.
    #
    # WHEN this fires is "as soon as the routes exist", which is boot only where
    # routes load during initialization. Railties ends set_routes_reloader_hook
    # with `reloader.execute_unless_loaded if !app.routes.is_a?(Engine::
    # LazyRouteSet) || app.config.eager_load` — so an eager-loading environment
    # (production, staging, the environments a bake actually runs in) warns at
    # boot, while development's lazy route set defers it to the first request or
    # reload. Forcing the routes early to make "boot" literally true would
    # defeat LazyRouteSet for every host to make one log line punctual.
    #
    # after_routes_loaded, NOT to_prepare, and that is load-bearing. The
    # preflight reads CurrentScope.catalog, and the catalog MEMOIZES its
    # derivation — so asking it before the routes are drawn caches an EMPTY
    # permission set for the life of the process, and every gated request then
    # raises "not in the permission catalog". Measured, not reasoned: the dummy
    # app booted with 44 catalog keys and 0 with the check on to_prepare. This
    # hook is the one place Rails guarantees the route set is complete, and it
    # re-runs on every routes reload, so a dev edit is re-checked.
    #
    # WHAT THIS ACTUALLY EXECUTES, because "log-only" undersold it: one
    # `klass.new` per routed SoD controller, to read its current_scope_model
    # declaration (an instance method — there is no other way to ask). Declared
    # MODELS are answered from the class and are NOT instantiated unless the
    # scan is about to name one, so a host's `after_initialize` runs only for a
    # model that is already a candidate finding. Failures are absorbed and surfaced through
    # the scan Result's skipped list, so the risk is not a crash — it is that a side
    # effect in a host constructor has already happened by the time the rescue
    # runs. Nothing here writes to the database, and it is a no-op until a host
    # opts into SoD (config.sod_actions defaults to []).
    initializer "current_scope.sod_preflight" do |app|
      app.config.after_routes_loaded do
        CurrentScope::SodPreflight.warn!
      end
    end

    # #151. subject_id/resource_id are string columns now, so an integer key and a
    # UUID both store whole and there is nothing left to scan stored rows for.
    # What a config value CAN still name is a subject class whose primary key is
    # not one value — composite, or absent — which no grant could ever identify.
    # Cheap early warning; the write validations are the guarantee.
    #
    # Silent when it cannot introspect (no connection, no table, unresolved
    # class): "unknown" must not become "broken", or `rails db:create` on a fresh
    # checkout would raise.
    def self.validate_subject_key!
      klass = CurrentScope.config.subject_class
      klass = klass.to_s.safe_constantize if klass.is_a?(String) || klass.is_a?(Symbol)
      return unless klass.respond_to?(:primary_key)
      return if CurrentScope.storable_key?(klass)

      raise ConfigurationError, CurrentScope.unstorable_key_error(klass, role: "subject")
    rescue ActiveRecord::ActiveRecordError
      # This rescue is scoped to THIS check on purpose. It exists to keep an
      # unknown subject class quiet; the schema guard must never share it, or a
      # transient database error at boot would read as "all clear" and the host
      # would serve with the escalation live — a security guard failing open.
      Rails.logger&.warn("[CurrentScope] subject key check skipped — could not introspect the database (#151).")
      nil
    end

    # #151 is fixed by a MIGRATION, and a gem upgrade does not run it. A host that
    # bundles 0.5 and deploys without `current_scope:install:migrations && db:migrate`
    # keeps integer id columns and keeps the full escalation — silently, because
    # every code path here behaves correctly against the schema it is given.
    #
    # So check the schema itself and refuse to boot. This is the one check that
    # cannot be a validation: the damage is in the column type, not the next write.
    def self.grant_columns_widened!
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
    private_class_method :check_id_column!

    # Collation matters as much as type on MySQL: its default is case AND accent
    # insensitive, so "ABC" and "abc" — or "jose" and "josé" — are the same
    # record. A database built from schema.rb has the right column type and the
    # wrong collation, which is the common case for a new app and for CI.
    def self.check_collation!(model, column)
      info = model.columns_hash[column]
      return if info.nil? || info.collation.nil? || info.collation.end_with?("_bin")

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
    private_class_method :check_collation!

    # The GRANT tables' connection, not ActiveRecord::Base's. The columns being
    # judged come from RoleAssignment.columns_hash, so the adapter question has
    # to be asked of the same database those columns live in — a host that puts
    # the engine's tables on a second connection would otherwise be judged by the
    # wrong server's collation rules.
    def self.mysql?
      CurrentScope.mysql?(CurrentScope::RoleAssignment.connection)
    end
    private_class_method :mysql?

    # Rake tasks that must be allowed to BOOT even against an unmigrated schema.
    #
    # The check above raises from after_initialize, which every Rails command
    # runs — including `db:migrate`, the command its own error message tells the
    # host to run. Without an exemption an upgrading host is stuck: the app
    # refuses to boot and the repair refuses to run, for the same reason.
    #
    # `assets:` is here for the same reason, one step less obvious: a deploy
    # pipeline that precompiles before migrating boots the app with a live
    # connection to the not-yet-migrated database, so the build dies before it
    # ever reaches db:migrate.
    #
    # What is deliberately NOT exempt is anything that goes on to serve or run
    # host code — server, console, runner. Refusing those is what actually
    # protects the host; only the build-and-repair path is let through.
    BOOT_EXEMPT_TASKS = %w[
      db: app:db: current_scope:install current_scope:repair_schema
      app:current_scope:repair_schema assets:
    ].freeze

    # …except these. The `db:` prefix is there for the REPAIR path, and two db:
    # tasks repair nothing — they run the host's own code. Seeding an unmigrated
    # database is the worst case this guard exists for: seeds routinely create
    # grants through this engine, and on the pre-migration schema those are
    # exactly the writes that collapse two subjects into one. A deny list rather
    # than an allow list of every db: task, so a Rails release that adds a new
    # schema task does not silently start refusing to boot.
    BOOT_REFUSED_TASKS = %w[
      db:seed db:fixtures:load app:db:seed app:db:fixtures:load
    ].freeze

    def self.running_a_database_task?
      return false unless defined?(Rake) && Rake.respond_to?(:application)

      tasks = Rake.application.top_level_tasks
      return false if tasks.any? { |task| BOOT_REFUSED_TASKS.include?(task) }

      tasks.any? { |task| task.start_with?(*BOOT_EXEMPT_TASKS) }
    rescue StandardError
      # No rake application in scope (a server or console): not a database task.
      false
    end
    private_class_method :running_a_database_task?
  end
end
