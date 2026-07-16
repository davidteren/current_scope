require "current_scope/version"
require "current_scope/configuration"
require "current_scope/permission_catalog"
require "current_scope/permission_grid"
require "current_scope/resolver"
require "current_scope/permissions"
require "current_scope/context"
require "current_scope/scopeable"
require "current_scope/mutation_guard"
require "current_scope/guard"
require "current_scope/gating_tripwire"
require "current_scope/engine"

module  CurrentScope
  # Raised when the resolver denies an action gated by Guard (or when the
  # management UI is accessed without a full-access role). Carries an optional
  # machine-readable reason, surfaced on the response as X-Current-Scope-Reason
  # by current_scope_denied:
  #
  #   :sod_veto           — the record's initiator can't perform an SoD action on it
  #   :no_grant           — nothing granted the permission (the default deny)
  #   :impersonation_gate — a mutation while impersonating, which is read-only
  #   :not_full_access    — the engine's management UI, which only full_access enters
  #
  # Every denial in the gem raises this and lands in current_scope_denied, so a
  # denial cannot exist that forgets its reason. (:sod_bypassed is the one
  # audited ALLOW, so it is set by the Guard rather than raised here.)
  class AccessDenied < StandardError
    attr_reader :reason

    def initialize(message = nil, reason: nil)
      super(message)
      @reason = reason
    end
  end

  # Raised when the host is wired up wrong (missing hook, bad config). Always
  # raised loudly — an authorization library must never turn a configuration
  # mistake into a silent allow or an undiagnosable deny.
  class ConfigurationError < StandardError; end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def resolver
      @resolver ||= Resolver.new
    end

    def catalog
      @catalog ||= PermissionCatalog.new
    end

    def reset_catalog!
      @catalog = nil
    end

    # The cross-controller nudge warns once per site (see below). That latch is
    # per-process, so it must be clearable: a leaked one silently disarms the
    # warning for every later test and makes the suite order-dependent. Also
    # cleared on engine to_prepare, since a reload can change what's routed.
    def reset_cross_controller_warnings!
      @cross_controller_warned = nil
    end

    # Models that opted into the scoped-role picker via CurrentScope::Scopeable.
    # Stored as class-name strings and resolved lazily so dev-mode reloading
    # never pins a stale constant. Rebuilt from scratch on every engine
    # to_prepare (see reset_scopeable_registry!).
    def scopeable_registry
      @scopeable_registry ||= Set.new
    end

    def register_scopeable(model_name)
      scopeable_registry << model_name.to_s
    end

    def scopeable_resources
      scopeable_registry.map(&:constantize).sort_by(&:name)
    end

    def reset_scopeable_registry!
      @scopeable_registry = Set.new
    end

    # The single entry point behind every allowed_to? call.
    # `action` is either a full permission key ("admin/reports#approve") or a
    # bare action name resolved against `record`'s route key, falling back to
    # `controller_path`.
    def allowed?(action, subject:, record: nil, controller_path: nil, actor: nil)
      resolver.allow?(
        subject: subject,
        permission: permission_key(action, record: record, controller_path: controller_path),
        record: record,
        actor: actor
      )
    end

    # The list-side companion to allowed?. Returns a chainable relation of the
    # records of `model` the subject may act on under `permission` — same
    # grants, same fail-closed rules as the per-record gate. `permission` is a
    # resolved key ("projects#index"); the mixin derives the default.
    def scope_for(subject:, model:, permission:)
      resolver.scope_for(subject: subject, model: model, permission: permission)
    end

    # THE human-label fallback chain, shared by the UI helpers
    # (ApplicationHelper#current_scope_label) and the audit ledger
    # (Event.label_for) — one definition, so a record can never render as
    # "Apollo" on screen while being frozen into the ledger as "Project #7".
    # Chain: the record's own current_scope_label (Scopeable provides one) →
    # human identifiers (name/email/title) → "Model #id" → to_s. Returns nil
    # for nil; callers choose their own nil presentation ("(none)" in views).
    def label_for(record)
      return if record.nil?
      return record.current_scope_label if record.respond_to?(:current_scope_label)

      name = record.try(:name).presence || record.try(:email).presence || record.try(:title).presence
      return name if name
      return "#{record.model_name.human} ##{record.id}" if record.respond_to?(:model_name)

      record.to_s
    end

    def permission_key(action, record: nil, controller_path: nil)
      action = action.to_s
      return action if action.include?("#")

      if record.respond_to?(:model_name)
        route_key = record.model_name.route_key
        # When the current controller handles this record type (possibly under
        # a namespace — admin/reports for a Report), its path is the key the
        # Guard enforces, so prefer it: the view must agree with the gate.
        return "#{controller_path}##{action}" if controller_path&.split("/")&.last == route_key

        warn_on_cross_controller_derivation(action, route_key, controller_path)
        return "#{route_key}##{action}"
      end
      return "#{controller_path}##{action}" if controller_path

      raise ArgumentError,
            "cannot derive a permission key for #{action.inspect} — pass a record, " \
            "a full \"controller#action\" string, or call from a controller/view"
    end


    # Impersonation boundary events. The impersonated identity is an EXPLICIT
    # argument (not read from the ambient pair): at act-as START the ambient
    # actor still equals the effective user — Current re-resolves next request —
    # so an ambient-only recorder would lose who was impersonated. Call these
    # from the host's start/stop-impersonation endpoints.
    def record_impersonation_started!(subject)
      require_actor_method!
      Event.record!(event: "impersonation.started", target: subject)
    end

    def record_impersonation_stopped!(subject)
      require_actor_method!
      Event.record!(event: "impersonation.stopped", target: subject)
    end

    # Creates the two baseline roles every install needs: an Owner with
    # full_access (present and future permissions) and a Member baseline.
    # Call from db/seeds.rb.
    def seed_defaults!
      Role.find_or_create_by!(name: "Owner") { |r| r.full_access = true }
      Role.find_or_create_by!(name: "Member")
    end

    # Bootstrap the first admin: assign a role (default: the full_access Owner)
    # to `subject` as its one org-wide role. Idempotent — re-running sets the
    # same subject's org role to `role` rather than creating a duplicate (which
    # the one-role-per-subject uniqueness would reject anyway). Backs the
    # `current_scope:grant` rake task, so a fresh install doesn't need a console.
    def grant!(subject, role: nil)
      seed_defaults!
      role ||= Role.find_by!(name: "Owner")
      RoleAssignment.find_or_initialize_by(subject: subject).tap { |a| a.update!(role: role) }
    end

    private

    # The documented namespaced/custom-named controller foot-gun (#41): the short
    # form derived a DIFFERENT key than the gate on this controller enforces, so a
    # view can show a link that 403s (or hide one that works). Silent, and the
    # symptom appears nowhere near the cause.
    #
    # THIS SIGNAL IS AMBIGUOUS AND CANNOT BE MADE PRECISE. Two callers produce
    # byte-identical inputs here:
    #
    #   DashboardController renders Reports; allowed_to?(:show, report) is meant
    #     to mirror THIS controller's gate (dashboard#show)   -> foot-gun.
    #   DocumentsController lists documents with links to reports;
    #     allowed_to?(:show, report) genuinely means reports#show -> correct.
    #
    # Both have a controller path that doesn't end in the record's route_key, and
    # both route "{controller_path}##{action}". Nothing at the call site
    # distinguishes intent. An earlier draft treated the catalog hit as proof of
    # the foot-gun and warned "they disagree" — which is a false positive on every
    # row of the second case. (#59/#61 review, cubic)
    #
    # So: warn ONCE per (controller_path, action, route_key), and say plainly that
    # either reading may be right. One line per distinct site is a hint; one line
    # per row is noise people learn to filter — and a diagnostic that cries wolf is
    # worse than none, which is the whole thesis of this PR.
    #
    # ponytail: derivation is a hot path (every view helper call), so the flag is
    # checked FIRST — off costs one boolean and never touches the catalog.
    def warn_on_cross_controller_derivation(action, route_key, controller_path)
      return unless config.warn_on_cross_controller_derivation
      return if controller_path.nil? || controller_path.empty?
      # A "log-only" diagnostic that raises isn't log-only. catalog reads
      # Rails.application.routes, so a host that forces the flag on outside a
      # booted Rails must get silence, not a NameError out of key derivation.
      # (#61 review, qodo)
      return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

      gate_key = "#{controller_path}##{action}"
      return unless catalog.include?(gate_key)
      return unless cross_controller_warning_unseen?(gate_key, route_key)

      Rails.logger&.warn(
        "[CurrentScope] allowed_to?(#{action.to_sym.inspect}, <#{route_key.singularize.camelize}>) on " \
        "#{controller_path} derived \"#{route_key}##{action}\", but the gate here enforces " \
        "\"#{gate_key}\". If you meant this controller's own gate, they disagree — pass the explicit " \
        "key: allowed_to?(\"#{gate_key}\"). If you're asking about a different resource than this " \
        "controller handles, the derived key is correct and this is expected. Warned once per site."
      )
    end

    # ponytail: a plain Set, not a Mutex — worst case under a race is one extra
    # line, and a flood is the thing being prevented. Dev/test only by default.
    def cross_controller_warning_unseen?(gate_key, route_key)
      @cross_controller_warned ||= Set.new
      @cross_controller_warned.add?("#{gate_key}|#{route_key}") ? true : false
    end

    # A2: the boundary events are the one place a host declares it is actually
    # impersonating. If actor_method is unset there, the entire act-as security
    # model is silently inert — so fail LOUD instead of recording an
    # impersonation with no real actor behind it. (The permission path can't
    # detect this: with actor_method nil, actor falls back to user, so
    # impersonating? is always false and a per-request check would nag every
    # RBAC-only host. This seam only fires when the host declares intent.)
    def require_actor_method!
      return unless config.actor_method.nil?

      raise ConfigurationError,
            "impersonation boundary event recorded while config.actor_method is unset. " \
            "Act-as security is inert without it: the read-only-while-impersonating " \
            "MutationGuard never engages, the SoD :either veto can't fire, and audit rows " \
            "are attributed to the impersonated subject instead of the real actor. Set " \
            "config.actor_method to the controller method that returns the real actor."
    end
  end
end
