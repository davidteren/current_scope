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
  #   5. scoped role,  — the target is record-less (nil for a collection action,
  #      record-less     a Class for a class-form check), so no specific record
  #                      can be named: ANY scoped grant ticking the key opens it.
  #                      scope_for then narrows the list to those records.
  #   6. default-deny  — nothing granted means denied.
  class Resolver
    INITIATOR_METHOD = :current_scope_initiator
    # Host-defined per-record opt-in for break-glass. Absent ⇒ never bypassed
    # (fail-closed, no raise — unlike a missing initiator, absence here is
    # unambiguous).
    BYPASS_METHOD = :current_scope_sod_bypassed?

    # Public contract: boolean. `actor` is the REAL principal behind the
    # request (defaults to the subject — no impersonation); it only widens the
    # SoD veto under config.sod_identity == :either.
    def allow?(subject:, permission:, record: nil, actor: nil, model: nil)
      decide(subject: subject, permission: permission, record: record, actor: actor, model: model).first
    end

    # Internal decision: returns [allowed_bool, reason_or_nil]. The reason is a
    # machine-readable cause the Guard surfaces: :sod_veto / :no_grant on a
    # denial, and :sod_bypassed on the one AUDITED allow (break-glass). Ordinary
    # allows carry nil. The resolver — shared across threads — holds no
    # per-decision state; the reason rides in the return tuple, not on self.
    #
    # `model:` (#50) is the type the controller's current_scope_model hook
    # declared for its collection actions, or nil when unknown. Accepted and
    # DELIBERATELY unread so far — threading (U1) and binding (U2) land
    # separately so each is provable on its own; U2 binds the record-less
    # branch by it. It stays a parameter, never state, per the purity rule above.
    def decide(subject:, permission:, record: nil, actor: nil, model: nil) # rubocop:disable Lint/UnusedMethodArgument
      return [ false, :no_grant ] if subject.nil?

      case sod_decision(subject: subject, actor: actor, permission: permission, record: record)
      when :veto   then return [ false, :sod_veto ]
      when :bypass then return [ true, :sod_bypassed ] # break-glass: privileged, audited override
      end

      role = org_role(subject)
      return [ true, nil ] if role&.full_access?
      return [ true, nil ] if role&.grants?(permission)
      return [ true, nil ] if scoped_grant?(subject: subject, permission: permission, record: record)
      return [ true, nil ] if record_less_scoped_grant?(subject: subject, permission: permission, record: record)

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

    # Whether the separation-of-duties veto is in a position to decide about this
    # pair at all: the action must be SoD-listed AND there must be an actual
    # record instance to name an initiator from. The veto is defined in terms of
    # who raised a record, so with no record it has nothing to measure and is
    # skipped — that covers a collection action's nil, a class-form check like
    # allowed_to?(:approve, Report), and equally a host hook that handed back
    # something that isn't a record at all (`params[:id]`, a String).
    #
    # PUBLIC because "the veto did not run" and "the veto passed" are different
    # facts, and a caller that acts on the difference must be able to ASK rather
    # than infer it. It is not inferable from the decision: a skipped veto falls
    # through to the ordinary grant check, so it surfaces as :no_grant or an
    # ordinary allow — never as anything that says "SoD abstained". Report mode
    # (#37) has to know, because :no_grant is the one reason it downgrades.
    #
    # This is the single definition of the condition, deliberately: sod_decision
    # reads it too. Two copies of "did the veto run" is two copies that drift,
    # and the copy that drifts is the one guarding the fraud control. (#59 review)
    def sod_veto_applies?(permission:, record:)
      sod_action?(permission) && record.respond_to?(:new_record?)
    end

    # The blind spot: an SoD-listed action whose veto could NOT run. The decision
    # that comes back for one of these is :no_grant or an ordinary allow — the
    # veto contributed nothing to it. Anyone treating that :no_grant as "SoD was
    # fine with this" is reading a silence as an answer.
    #
    # The same hazard the record-less scoped branch already refuses (see
    # sod_action? below) and that config.warn_on_nil_sod_record surfaces on the
    # allow path: a host mis-gating a member SoD action. In :enforce this costs
    # nothing — :no_grant is a 403 regardless, so the skipped veto never decides
    # anything. Report mode is what makes it matter, because :no_grant is exactly
    # what it downgrades. (#37, #59 review)
    def sod_veto_skipped?(permission:, record:)
      sod_action?(permission) && !sod_veto_applies?(permission: permission, record: record)
    end

    # Does this subject hold a scoped grant that satisfies `permission` on ANY
    # record? Read-only, and deliberately unfiltered by resource — that absence
    # IS the question: the grant exists, but the gate never got a record for it
    # to apply to.
    #
    # DIAGNOSTICS ONLY (#41). It answers a COUNTERFACTUAL — "had the controller
    # declared its record hook, would a scoped grant have allowed this?" — and
    # must never decide anything. The record it would need in order to BE a
    # decision is exactly what's missing; that's the bug it reports.
    #
    # Reads roles_granting (full_access ∪ ticking), and that is right BECAUSE
    # the counterfactual binds to a record: with a real record, scoped_grant?
    # honors a scoped full_access role, so an honest "would it have been
    # allowed?" must honor it too. The same reuse in a branch that binds to NO
    # record was #49's P0 escalation — one scoped grant passing every
    # collection gate in the app. The binding is the entire difference, which is
    # why this is a question and not a gate.
    def scoped_grant_exists?(subject:, permission:)
      return false if subject.nil?

      ScopedRoleAssignment.where(subject: subject, role_id: roles_granting(permission)).exists?
    end

    private

    # Role ids that satisfy `permission`: full_access (grants everything) or an
    # explicit grant of the key. The one place "does this role grant it?" is
    # expressed for scoped grants. Including full_access is only safe while no
    # caller turns an unbound match into a PERMIT. Three callers, each safe for
    # its own reason: scoped_grant? binds `resource:` to the exact record;
    # scope_for binds `resource_type:` and answers in record ids
    # (.select(:resource_id)) for the caller to narrow, never a boolean permit;
    # scoped_grant_exists? binds nothing and is therefore diagnostics-only —
    # its own comment says why it must never decide. A new caller must fit one
    # of those three shapes or use roles_ticking. (#65 cites this comment as
    # the safety condition; it is load-bearing, keep it true.)
    def roles_granting(permission)
      Role.where(full_access: true).or(Role.where(id: roles_ticking(permission)))
    end

    # Role ids that EXPLICITLY tick `permission` — full_access roles deliberately
    # excluded, whether or not they also carry a RolePermission row. Only for the
    # record-less branch, which binds the grant to no record at all: honoring
    # full_access there would mean one scoped full_access grant on one record
    # ("Owner of Report #7") opened EVERY record-less gate in the host app —
    # every #index and #create on every controller — since a full_access role
    # satisfies every key. That is the `resource:` bound scoped_grant? applies
    # and the record-less branch cannot.
    #
    # The `where.not` is load-bearing, not belt-and-braces: a role can be
    # full_access AND retain explicit rows (tick grid cells, then flip the
    # full-access toggle), and matching on the leftover row alone would walk it
    # straight back through the branch full_access is barred from.
    #
    # roles_granting's set is unchanged by this exclusion — it unions
    # full_access back in, so full_access ∪ (ticking − full_access) == the same
    # roles it always matched.
    def roles_ticking(permission)
      RolePermission
        .where(permission_key: permission)
        .where.not(role_id: Role.where(full_access: true).select(:id))
        .select(:role_id)
    end

    # The separation-of-duties outcome for this decision: :none (no conflict, or
    # not an SoD action), :veto (the initiator is acting on their own record and
    # the veto stands), or :bypass (a conflict exists but break-glass lifts it).
    # Pure — reads only; the audit write for a :bypass happens at the Guard.
    def sod_decision(subject:, actor:, permission:, record:)
      return :none unless sod_veto_applies?(permission: permission, record: record)

      # SoD is a structural guarantee — "cannot determine the initiator" must
      # never mean "permit". A record type where SoD genuinely doesn't apply
      # declares the hook returning nil.
      unless record.respond_to?(INITIATOR_METHOD, true)
        raise ConfigurationError,
              "#{record.class.name}##{INITIATOR_METHOD} is not defined, but " \
              "\"#{permission}\" is a separation-of-duties action (config.sod_actions). " \
              "Define #{INITIATOR_METHOD} on #{record.class.name} (return nil to exempt " \
              "a record), or remove \"#{permission.split('#').last}\" from config.sod_actions."
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

    # A record-less target is allowed when the subject holds ANY scoped grant
    # whose role ticks the key — the list-side complement to scope_for, which
    # then narrows the collection to the granted records. Without this, the two
    # halves of the per-record feature contradict each other: the gate turns a
    # scoped-only subject away from their index, and the org-wide grant that gets
    # them past it makes scope_for return every record.
    #
    # "Record-less" is a CLOSED set of exactly two shapes, tested positively:
    #
    #   nil     — a collection action; the Guard's hook returns nil when there is
    #             no record (guard.rb), which is the documented contract.
    #   a Class — the class form, allowed_to?(:index, Report).
    #
    # Positive, never `unless record.respond_to?(:new_record?)`: a negative test
    # admits an OPEN set, so a host whose current_scope_record wrongly returns
    # params[:id] (a String) or any other non-record would land here and be
    # ALLOWED on the strength of a grant held over some *other* record — a
    # fail-open in a fail-closed engine, and a breach of this branch's own
    # invariant that a grant on X must not act on Y. Anything that is not
    # literally nil-or-a-Class is not a record-less target and gets no say here.
    #
    # Consequence, deliberate: an UNPERSISTED instance (Report.new) is not
    # record-less by this test, and scoped_grant? needs persisted? — so it is
    # denied, while the class form is allowed. That asymmetry is only reachable
    # by gating a collection action with Model.new instead of the documented nil,
    # and it fails CLOSED (a 403 the host sees immediately), which is the safe
    # direction to be wrong in.
    #
    # Requires an EXPLICIT tick (roles_ticking, not roles_granting): this is the
    # only grant check that binds to no record, so a full_access role — which
    # satisfies every key — would turn one scoped grant on one record into a
    # pass on every #index and #create in the host app. "Owner of Report #7"
    # means full access to Report #7, not to every collection in the product.
    # The cost of that strictness: a scoped full_access role does not open its
    # own index either, so it keeps the pre-existing 403 that #19 fixes for
    # explicitly-ticked roles. Reaching that needs the Guard to tell the
    # resolver which model the collection is (see OQ-2) — until then, deny is
    # the honest answer rather than an app-wide wildcard.
    #
    # Deliberately NOT memoized, unlike org_role. The memo there caches one
    # lookup keyed by subject, invalidated by RoleAssignment writes alone. This
    # predicate's answer derives from three tables (scoped assignments, roles,
    # role permissions), so a memo would need invalidation hooks on all three —
    # and a stale entry here is a stale ALLOW. Only record-less checks by
    # scoped-only subjects reach this line (org and full_access short-circuit
    # above), so the cost is a query on a handful of nav-level checks per page,
    # not the per-row gate. Revisit if that ever shows up in a profile.
    def record_less_scoped_grant?(subject:, permission:, record:)
      return false unless record.nil? || record.is_a?(Class)
      return false if sod_action?(permission)

      ScopedRoleAssignment
        .where(subject: subject, role_id: roles_ticking(permission))
        .exists?
    end

    # An SoD action is record-targeted BY DEFINITION — "the subject who
    # initiated a record can never approve THAT record". So a record-less SoD
    # check is a contradiction in terms: there is no record for the veto to
    # measure, and `sod_decision` returns :none for exactly that reason. Opening
    # such a gate off a scoped grant would let a host that mis-gates a member
    # SoD action (current_scope_record returning nil on `reports#approve` —
    # precisely what warn_on_nil_sod_record exists to catch) hand out the action
    # with the four-eyes veto silently skipped. The veto is a structural
    # guarantee, so it must not rest on an opt-in dev warning; deny instead.
    #
    # This does NOT close the older org-grant asymmetry — a nil record on an SoD
    # action still passes for an org-wide grant, which is characterized and
    # pinned in test/sod_nil_record_test.rb. It only stops the record-less scoped
    # branch from widening that hole to scoped grants too.
    def sod_action?(permission)
      CurrentScope.config.sod_actions.include?(permission.split("#").last)
    end
  end
end
