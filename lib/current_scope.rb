require "current_scope/version"
require "current_scope/subject_identity"
require "current_scope/identity_setup"
require "current_scope/configuration"
require "current_scope/permission_catalog"
require "current_scope/permission_grid"
require "current_scope/resolver"
require "current_scope/permissions"
require "current_scope/context"
require "current_scope/scopeable"
require "current_scope/parent_chain"
require "current_scope/grant_diagnosis"
require "current_scope/mutation_guard"
require "current_scope/guard"
require "current_scope/gating_tripwire"
require "current_scope/gating_reflection"
require "current_scope/sod_preflight"
require "current_scope/schema_guard"
require "current_scope/polymorphic_registry"
require "current_scope/full_access_lock"
require "current_scope/definitions_document"
require "current_scope/engine"

module  CurrentScope
  # Raised when the resolver denies an action gated by Guard (or when the
  # management UI is accessed without a full-access role). Accessors:
  #
  #   #permission — denied key (stable API for branded 403s). Defaults to the
  #                 positional message when permission: is omitted so legacy
  #                 raise sites still populate it. Prefer this over #message.
  #   #message    — StandardError message (positional arg). Gem raise sites pass
  #                 the key as both message and permission; they can diverge if
  #                 a caller passes an explicit permission: keyword.
  #   #reason     — machine-readable cause (also on X-Current-Scope-Reason)
  #   #record     — the record under decision when the gate had one; nil for
  #                 collection / impersonation-gate denials
  #   #subject    — effective subject when known; nil if none was in scope
  #
  # Reasons surfaced by current_scope_denied:
  #
  #   :sod_veto           — the record's initiator can't perform an SoD action on it
  #   :no_grant           — nothing granted the permission (the default deny)
  #   :model_undeclared   — a record-less deny that a scoped grant would have
  #                         opened, had the controller declared current_scope_model
  #                         to bind it to a type (#50). Fail-closed, with the fix named.
  #   :model_invalid      — its sibling: current_scope_model WAS declared but
  #                         returned something the shape guard refuses (a String,
  #                         an instance, an abstract class — not a concrete AR
  #                         class). Same cell, different fix, so a different label.
  #   :impersonation_gate — a mutation while impersonating, which is read-only
  #   :not_full_access    — the engine's management UI, which only full_access enters
  #
  # Every denial in the gem raises this and lands in current_scope_denied, so a
  # denial cannot exist that forgets its reason. (:sod_bypassed is the one
  # audited ALLOW, so it is set by the Guard rather than raised here.)
  class AccessDenied < StandardError
    attr_reader :reason, :permission, :record, :subject

    def initialize(message = nil, reason: nil, permission: nil, record: nil, subject: nil)
      super(message)
      @reason = reason
      # permission defaults to message so older raise sites and branded-403
      # recipes that only pass the key positionally still populate #permission.
      @permission = permission || message
      @record = record
      @subject = subject
    end
  end

  # Raised when the host is wired up wrong (missing hook, bad config). Always
  # raised loudly — an authorization library must never turn a configuration
  # mistake into a silent allow or an undiagnosable deny.
  class ConfigurationError < StandardError; end

  # The width of the polymorphic grant id columns (#151). Named here so the
  # length guard and the migration cannot drift apart; the migration keeps its own
  # copy because a migration must not depend on the gem's runtime constants.
  KEY_LIMIT = 64

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    # One definition, on the facade, exactly as mysql? is. Two unrelated callers
    # ask it — the PLACEHOLDER=1 refusal in IdentitySetup and the impersonation
    # mutation opt-in in Configuration — and neither should reach into an
    # identity file for a basic environment check.
    def production?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
    end

    # Portable identity of a subject (#158). Default is the primary key.
    #
    # Refuses a record that is not config.subject_class, because the inverse is
    # not symmetric: resolve_subject only ever returns a subject_class row. A
    # key minted from another model with the same column value would therefore
    # resolve to a DIFFERENT record in the next environment — silently, and
    # holding whatever grants that record holds.
    def identify_subject(subject)
      return if subject.nil?

      klass = config.resolved_subject_class
      if klass && !subject.is_a?(klass)
        raise ConfigurationError,
              "#{subject.class} is not config.subject_class (#{klass}), so it has " \
              "no portable identity. resolve_subject only ever returns a #{klass}, " \
              "so this key would resolve to a different record."
      end

      config.subject_identity_resolver.identify(subject)
    end

    # Inverse of identify_subject. Returns the subject in this environment, or
    # nil when missing. Never inserts. Sugar resolvers raise if two rows match.
    #
    # Holds the SAME class invariant identify_subject enforces. The sugar
    # resolvers query subject_class and cannot break it, but a host object's
    # resolve is host code, and a guard that covers only the outbound direction
    # is not an invariant.
    def resolve_subject(key)
      found = config.subject_identity_resolver.resolve(key)
      return found if found.nil?

      klass = config.resolved_subject_class
      if klass && !found.is_a?(klass)
        raise ConfigurationError,
              "config.subject_identity resolved #{key.inspect} to a #{found.class}, " \
              "but config.subject_class is #{klass}. A grant can only be held by a " \
              "#{klass}."
      end

      found
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
    def allowed?(action, subject:, record: nil, controller_path: nil, actor: nil, model: nil)
      resolver.allow?(
        subject: subject,
        permission: permission_key(action, record: record, controller_path: controller_path),
        record: record,
        actor: actor,
        model: model
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

    # #156 v1. Role definitions (name, description, full_access, permission
    # keys) as one YAML document. Assignments stay out.
    def export_definitions
      DefinitionsDocument.from_live.to_yaml
    end

    def diff_definitions(document)
      DefinitionsDocument.parse(document).diff
    end

    def import_definitions(document, confirm: false, actor: nil, subject: nil, snapshot_path: nil)
      DefinitionsDocument.parse(document).apply(
        confirm: confirm, actor: actor, subject: subject, snapshot_path: snapshot_path
      )
    end

    def rollback_definitions(snapshot, confirm: false, actor: nil, subject: nil)
      if snapshot.is_a?(String) && !snapshot.include?("\n") && !File.file?(snapshot)
        raise DefinitionsDocument::SnapshotMissing, "No snapshot at #{snapshot}"
      end

      DefinitionsDocument.parse(snapshot).apply(
        confirm: confirm, actor: actor, subject: subject,
        event: "definitions.rolled_back"
      )
    end

    # Bootstrap the first admin: assign a role (default: the full_access Owner)
    # to `subject` as its one org-wide role. Idempotent — re-running sets the
    # same subject's org role to `role` rather than creating a duplicate (which
    # the one-role-per-subject uniqueness would reject anyway). Backs the
    # `current_scope:grant` rake task, so a fresh install doesn't need a console.
    #
    # Seeds the default Owner/Member roles ONLY on the default path — the name
    # promises "assign a role", so a caller granting an explicit role must not
    # get a full-access Owner row created in their roles table as a side effect.
    #
    # Audit (#30): when the org role actually changes, records one
    # `org_role.assigned` / `org_role.changed` event, self-attributed to the
    # grantee with `details.source = "bootstrap"`. Same-role re-grants are a
    # no-op event-wise. Direct model writes and TestHelpers do not go through
    # this path and are not recorded (documented intentionally).
    def grant!(subject, role: nil)
      role ||= begin
        seed_defaults!
        Role.find_by!(name: "Owner")
      end

      RoleAssignment.transaction do
        assignment = RoleAssignment.find_or_initialize_by(subject: subject)
        prior_role = assignment.persisted? ? assignment.role : nil
        assignment.update!(role: role)

        if prior_role.nil?
          Event.record!(
            event: "org_role.assigned",
            target: subject,
            details: { role: role.name, source: "bootstrap" },
            actor: subject,
            subject: subject
          )
        elsif prior_role.id != role.id
          Event.record!(
            event: "org_role.changed",
            target: subject,
            details: { from: prior_role.name, to: role.name, source: "bootstrap" },
            actor: subject,
            subject: subject
          )
        end

        assignment
      end
    end

    # Registry lives in CurrentScope::PolymorphicRegistry. These four stay as
    # the public surface so hosts and tests do not need to know it moved.
    def storage_token(klass)
      PolymorphicRegistry.storage_token(klass)
    end

    def polymorphic_class(type)
      PolymorphicRegistry.class_for(type)
    end

    def rebuild_polymorphic_registry!
      PolymorphicRegistry.rebuild!
    end

    def polymorphic_registry
      PolymorphicRegistry.registry
    end

    # #151. `subject_id` and `resource_id` are string columns, so ANY single-value
    # primary key stores whole — an integer as "1", a UUID as "7f00aaaa-…". What
    # still cannot be stored is a key that is not one value: a composite key is an
    # array, and a model with no primary key names no record at all. Grants on
    # those are refused rather than written as something that identifies the wrong
    # row, or nothing.
    def storable_key?(klass)
      klass.primary_key.is_a?(String)
    end

    # Whether a connection speaks MySQL, in one place. MySQL is the only adapter
    # #151 has to treat specially (its default collation folds case and accents,
    # and it needs CHAR rather than TEXT in a cast), and three separate copies of
    # this regex would be three chances to disagree.
    #
    # Takes a CONNECTION rather than reading ActiveRecord::Base's: in a host that
    # puts the grant tables on a different database from its subject models, the
    # answer differs per connection, and asking the wrong one produces a cast or
    # a collation the target server rejects.
    def mysql?(connection = ActiveRecord::Base.connection)
      connection.adapter_name.match?(/mysql|trilogy|maria/i)
    end

    # #151, VALUE side. storable_key? asks whether the CLASS can be named by one
    # id; this asks whether THIS id is a legal one for that class.
    #
    # The columns hold any string now, so a grant can be written naming a
    # bigint-keyed model with a UUID. Nothing about the write looks wrong — and
    # the read path then casts that string back into the model's own key type,
    # where String#to_i turns "7f00aaaa-…" into 7 and the grant reaches record 7,
    # which it never named. That is #151 again, moved from the write side to the
    # read side by the very widening that fixed the write side.
    #
    # A canonical id is one that survives a round trip through its own key type.
    # Every id the engine itself writes is canonical by construction (it stores
    # `record.id` through exactly this cast), so this rejects only ids that could
    # not have come from a real record: "7f00aaaa-…" for a bigint key, "007" for
    # any key (it would match record 7), "7" for a Postgres uuid key.
    def canonical_key?(klass, value)
      # A blank id names no record. The column accepts "", but "" is a canonical
      # key for nothing — bless it and a directly-inserted grant with an empty id
      # would resolve to whatever "" casts to for the key type. Fail closed here,
      # in the guard, rather than relying on a caller or the adapter to drop it.
      return false if value.to_s.empty?

      key = klass.primary_key
      return false unless key.is_a?(String)

      type = klass.type_for_attribute(key)
      cast = type.cast(value)
      type.serialize(cast) # integer types raise when the value exceeds the column range
      cast.to_s == value.to_s
    rescue StandardError
      # Cannot introspect the key type (no connection, no table, exotic type):
      # refuse rather than guess. Callers use this to DENY, so failing here
      # fails closed.
      false
    end

    # A key that does not FIT is as dangerous as one that is not a single value.
    # MySQL outside strict mode truncates silently, so two keys sharing a 64-char
    # prefix would collapse into one identity — #151 by another route. Checked in
    # Ruby so every adapter fails the same way instead of depending on sql_mode.
    def key_too_long?(value)
      value.to_s.length > KEY_LIMIT
    end

    def unstorable_key_error(klass, role: "subject")
      key = begin
        klass.primary_key
      rescue StandardError
        nil
      end
      shape = key.is_a?(Array) ? "a composite primary key (#{key.inspect})" : "no primary key"

      "#{klass.name} has #{shape}, and CurrentScope stores a #{role} id as one value. " \
        "A grant needs to name exactly one record. Use a model with a single-column " \
        "primary key — integer or UUID both work."
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
