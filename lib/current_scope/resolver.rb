module CurrentScope
  # The decision point. Every allow/deny question in the system routes through
  # here, in a fixed order:
  #
  #   1. SoD veto      — the record's initiator can never perform an SoD action
  #                      on it. Reads two identities: the effective subject and
  #                      (under sod_identity :either) the real actor behind an
  #                      impersonated session. Overrides everything, incl. full_access.
  #   2. full_access   — the subject's org-wide role grants all permissions,
  #                      present and future.
  #   3. org-wide role — the role's permission set includes this permission.
  #   4. scoped role   — a role held on THIS record grants the permission.
  #   5. default-deny  — nothing granted means denied.
  class Resolver
    INITIATOR_METHOD = :current_scope_initiator
    # Host-defined per-record opt-in for break-glass. Absent ⇒ never bypassed
    # (fail-closed, no raise — unlike a missing initiator, absence here is
    # unambiguous).
    BYPASS_METHOD = :current_scope_sod_bypassed?

    # Public contract: boolean. `actor` is the REAL principal behind the
    # request (defaults to the subject — no impersonation); it only widens the
    # SoD veto under config.sod_identity == :either.
    def allow?(subject:, permission:, record: nil, actor: nil)
      decide(subject: subject, permission: permission, record: record, actor: actor).first
    end

    # Internal decision: returns [allowed_bool, reason_or_nil]. The reason is a
    # machine-readable cause the Guard surfaces: :sod_veto / :no_grant on a
    # denial, and :sod_bypassed on the one AUDITED allow (break-glass). Ordinary
    # allows carry nil. The resolver — shared across threads — holds no
    # per-decision state; the reason rides in the return tuple, not on self.
    def decide(subject:, permission:, record: nil, actor: nil)
      return [ false, :no_grant ] if subject.nil?

      case sod_decision(subject: subject, actor: actor, permission: permission, record: record)
      when :veto   then return [ false, :sod_veto ]
      when :bypass then return [ true, :sod_bypassed ] # break-glass: privileged, audited override
      end

      role = org_role(subject)
      return [ true, nil ] if role&.full_access?
      return [ true, nil ] if role&.grants?(permission)
      return [ true, nil ] if scoped_grant?(subject: subject, permission: permission, record: record)

      [ false, :no_grant ]
    end

    # The subject's one org-wide role. Memoized per request (via Current) so the
    # many gate checks a single request makes don't each re-query — the decision
    # is identical, only the lookup is cached, keeping the resolver a pure
    # decision function over its inputs.
    def org_role(subject)
      CurrentScope::Current.memoized_org_role(subject) do
        RoleAssignment.find_by(subject: subject)&.role
      end
    end

    def full_access?(subject)
      !!(subject && org_role(subject)&.full_access?)
    end

    # The list-side complement to allow?: "which records of `model` may this
    # subject act on?". Reads the SAME org + scoped grants the gate reads, so a
    # host list can never drift from the per-record decision. Fail-closed (nil
    # subject / no grant → none) and flat — no parent/child cascade. SoD does
    # NOT apply: it vetoes record-targeted actions, not list membership.
    def scope_for(subject:, model:, permission:)
      return model.none if subject.nil?

      role = org_role(subject)
      return model.all if role&.full_access? || role&.grants?(permission)

      # Records on which the subject holds a scoped role that grants the key.
      # Query the polymorphic base_class (what scoped grants store), not the
      # passed model's name — otherwise scope_for(STISubclass) returns nothing
      # while the per-record gate (also keyed on base_class) would allow it. The
      # `model.where` still applies STI's own type predicate, so a subclass query
      # can't over-list sibling-subclass rows. An empty subquery yields an empty
      # (still chainable) relation.
      model.where(
        id: ScopedRoleAssignment
              .where(subject: subject, resource_type: model.base_class.name, role_id: roles_granting(permission))
              .select(:resource_id)
      )
    end

    private

    # Role ids that satisfy `permission`: full_access (grants everything) or an
    # explicit grant of the key. The one place "does this role grant it?" is
    # expressed for scoped grants — shared by the gate and scope_for.
    def roles_granting(permission)
      Role.where(full_access: true)
          .or(Role.where(id: RolePermission.where(permission_key: permission).select(:role_id)))
    end

    # The separation-of-duties outcome for this decision: :none (no conflict, or
    # not an SoD action), :veto (the initiator is acting on their own record and
    # the veto stands), or :bypass (a conflict exists but break-glass lifts it).
    # Pure — reads only; the audit write for a :bypass happens at the Guard.
    def sod_decision(subject:, actor:, permission:, record:)
      action = permission.split("#").last
      return :none unless CurrentScope.config.sod_actions.include?(action)
      # No veto without an actual record instance (collection actions get nil,
      # class-form checks like allowed_to?(:approve, Report) get the class).
      return :none unless record.respond_to?(:new_record?)

      # SoD is a structural guarantee — "cannot determine the initiator" must
      # never mean "permit". A record type where SoD genuinely doesn't apply
      # declares the hook returning nil.
      unless record.respond_to?(INITIATOR_METHOD, true)
        raise ConfigurationError,
              "#{record.class.name}##{INITIATOR_METHOD} is not defined, but " \
              "\"#{permission}\" is a separation-of-duties action (config.sod_actions). " \
              "Define #{INITIATOR_METHOD} on #{record.class.name} (return nil to exempt " \
              "a record), or remove \"#{action}\" from config.sod_actions."
      end

      initiator = record.send(INITIATOR_METHOD)
      return :none if initiator.blank?

      # The subject can never approve their own record. Under :either, neither
      # can a real actor who initiated it while impersonating a different
      # subject — impersonation must not become a self-approval loophole. Not
      # impersonating (actor == subject) collapses both checks to the same test.
      actor ||= subject
      conflict = initiator == subject ||
        (CurrentScope.config.sod_identity == :either && actor != subject && initiator == actor)
      return :none unless conflict

      sod_bypassed?(record: record, initiator: initiator) ? :bypass : :veto
    end

    # Break-glass: does an audited, privileged override lift the veto for this
    # record? All three must hold, live: the config switch is on, the record's
    # host hook opts in, and the INITIATOR (the identity the veto fired on —
    # KTD-2, so impersonation can't launder it) holds the bypass permission.
    def sod_bypassed?(record:, initiator:)
      return false unless CurrentScope.config.allow_sod_bypass

      # Re-entrancy is bounded ONLY because the bypass permission isn't itself an
      # SoD action (KTD-5) — the inner allowed? below returns at the SoD step
      # without recursing. Enforce that invariant loudly rather than trusting the
      # host to honor the doc comment: a bypass action in sod_actions would
      # recurse to a SystemStackError.
      bypass_action = CurrentScope.config.sod_bypass_permission.to_s.split("#").last
      if CurrentScope.config.sod_actions.include?(bypass_action)
        raise ConfigurationError,
              "config.sod_bypass_permission (#{CurrentScope.config.sod_bypass_permission.inspect}) is the " \
              "action #{bypass_action.inspect}, which is also in config.sod_actions. The bypass permission " \
              "must not be an SoD action — it would recurse. Remove #{bypass_action.inspect} from sod_actions."
      end

      # Absent hook ⇒ this type never breaks glass (fail-closed, no raise).
      return false unless record.respond_to?(BYPASS_METHOD, true) && record.send(BYPASS_METHOD)

      CurrentScope.allowed?(CurrentScope.config.sod_bypass_permission, subject: initiator, record: record)
    end

    def scoped_grant?(subject:, permission:, record:)
      # `record` may be a class (allowed_to?(:create, Report)) — classes can't
      # hold scoped grants, only persisted records can.
      return false unless record.respond_to?(:new_record?) && record.persisted?

      ScopedRoleAssignment
        .where(subject: subject, resource: record, role_id: roles_granting(permission))
        .exists?
    end
  end
end
