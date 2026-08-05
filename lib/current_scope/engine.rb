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

    # #151. The write validations refuse NEW grants on a non-integer-keyed
    # subject, but a host that already holds collapsed rows keeps escalating on
    # every read — the damage is in the stored value, not the next insert. So the
    # configured subject class is checked once at boot and the deploy fails,
    # rather than serving one subject another's role.
    #
    # Deliberately silent when it cannot tell: no connection, no table (a boot
    # before migrate), or a subject_class that does not resolve yet. "Unknown"
    # must not become "broken" here, or `rails db:create` on a fresh checkout
    # would raise. That is why this cannot replace the write validations — it is
    # the early warning, they are the guarantee.
    #
    # Only the SUBJECT class is knowable at boot. Scoped grants can name any
    # model as a resource, so that side is covered by the validation alone.
    def self.validate_subject_key!
      configured_subject_key!
      stored_grant_keys!
    rescue ActiveRecord::ActiveRecordError
      # Any ActiveRecord error here means "cannot introspect yet" — boot before
      # migrate, no adapter configured, connection down. Deliberately broad: a
      # missed error class costs a deploy, an over-broad rescue costs only a
      # late warning, and the write validations remain the guarantee either way.
      nil
    end

    def self.configured_subject_key!
      klass = CurrentScope.config.subject_class
      klass = klass.to_s.safe_constantize if klass.is_a?(String) || klass.is_a?(Symbol)
      return unless klass.respond_to?(:primary_key)
      return unless klass.respond_to?(:table_exists?) && klass.table_exists?
      return if CurrentScope.integer_keyed?(klass)

      raise ConfigurationError, CurrentScope.non_integer_key_error(klass, role: "subject")
    end
    private_class_method :configured_subject_key!

    # The write validations stop NEW bad grants; they cannot undo rows a host
    # already stored on 0.2 to 0.4. Those rows keep escalating on every READ, and
    # `config.subject_class` does not see them — a scoped grant can name ANY model
    # as its resource. So read the type tokens actually present in the two grant
    # tables and refuse to boot if any resolves to a class the columns cannot hold.
    #
    # One DISTINCT query per column, over a low-cardinality set (a handful of
    # types, not a row per grant). Types that no longer resolve are skipped —
    # they are #90's inert grants, not this problem.
    def self.stored_grant_keys!
      {
        CurrentScope::RoleAssignment => %w[subject],
        CurrentScope::ScopedRoleAssignment => %w[subject resource]
      }.each do |model, sides|
        next unless model.table_exists?

        sides.each do |side|
          model.distinct.pluck(:"#{side}_type").each do |type|
            klass = CurrentScope.polymorphic_class(type)
            next if klass.nil? || CurrentScope.integer_keyed?(klass)

            raise ConfigurationError,
                  "#{model.name} holds grants on #{type}, and " +
                  CurrentScope.non_integer_key_error(klass, role: side)
          end
        end
      end
    end
    private_class_method :stored_grant_keys!
  end
end
