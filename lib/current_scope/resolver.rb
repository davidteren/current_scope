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

    # Public contract: boolean. `actor` is the REAL principal behind the
    # request (defaults to the subject — no impersonation); it only widens the
    # SoD veto under config.sod_identity == :either.
    def allow?(subject:, permission:, record: nil, actor: nil)
      decide(subject: subject, permission: permission, record: record, actor: actor).first
    end

    # Internal decision: returns [allowed_bool, reason_or_nil]. The reason is
    # populated only on denial (:sod_veto or :no_grant) so callers (Guard) can
    # surface a machine-readable cause without the resolver — memoized and
    # shared across threads — holding any per-decision state.
    def decide(subject:, permission:, record: nil, actor: nil)
      return [ false, :no_grant ] if subject.nil?
      return [ false, :sod_veto ] if sod_veto?(subject: subject, actor: actor, permission: permission, record: record)

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

    def sod_veto?(subject:, actor:, permission:, record:)
      action = permission.split("#").last
      return false unless CurrentScope.config.sod_actions.include?(action)
      # No veto without an actual record instance (collection actions get nil,
      # class-form checks like allowed_to?(:approve, Report) get the class).
      return false unless record.respond_to?(:new_record?)

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
      return false if initiator.blank?

      # The subject can never approve their own record. Under :either, neither
      # can a real actor who initiated it while impersonating a different
      # subject — impersonation must not become a self-approval loophole. Not
      # impersonating (actor == subject) collapses both checks to the same test.
      actor ||= subject
      initiator == subject ||
        (CurrentScope.config.sod_identity == :either && actor != subject && initiator == actor)
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
