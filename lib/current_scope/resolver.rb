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
  #                      can be named. An action in config.collection_read_actions
  #                      asks scope_for — the id-narrowed list query — so the gate
  #                      opens exactly when the list would show records
  #                      (full_access included, #65); any other action needs a
  #                      scoped grant EXPLICITLY ticking the key. scope_for then
  #                      narrows the list to those records.
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
    # declared for its collection actions, or nil when unknown. Only the
    # record-less branch reads it, to bind that otherwise type-unbound grant
    # check; every other branch ignores it. It stays a parameter, never state,
    # per the purity rule above.
    def decide(subject:, permission:, record: nil, actor: nil, model: nil)
      return [ false, :no_grant ] if subject.nil?

      case sod_decision(subject: subject, actor: actor, permission: permission, record: record)
      when :veto   then return [ false, :sod_veto ]
      when :bypass then return [ true, :sod_bypassed ] # break-glass: privileged, audited override
      end

      role = org_role(subject)
      return [ true, nil ] if role&.full_access?
      return [ true, nil ] if role&.grants?(permission)
      return [ true, nil ] if scoped_grant?(subject: subject, permission: permission, record: record)
      return [ true, nil ] if record_less_scoped_grant?(subject: subject, permission: permission, record: record, model: model)

      # A LABEL, not a decision (R7a): this deny would have been an ALLOW had
      # the controller declared current_scope_model and the grant ticked the
      # key of that type. Without the distinct reason it is indistinguishable
      # from an ordinary :no_grant, and the dev nudge that explains it is
      # dev/test-only — so the production host who most needs the cause
      # (403s after an upgrade) would be the one who cannot see it.
      if record_less_denied_for_unknown_type?(subject: subject, permission: permission, record: record, model: model)
        return [ false, :model_undeclared ]
      end

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
    #
    # Since #65 the record-less gate asks this same query (.exists?) for
    # actions in config.collection_read_actions, so gate and list cannot
    # drift for listed reads — they are one query.
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
    # caller turns an unbound match into a PERMIT. Four callers, each safe for
    # its own reason: scoped_grant? binds `resource:` to the exact record;
    # scope_for binds `resource_type:` and answers in record ids
    # (.select(:resource_id)) for the caller to narrow, never a boolean permit
    # — which is also why the record-less read gate (#65) is safe: it asks
    # scope_for and takes .exists? of the id-narrowed relation, so its answer
    # is still derived from the records the subject holds, not from the grant
    # row alone; scoped_grant_exists? binds nothing and is therefore
    # diagnostics-only — its own comment says why it must never decide;
    # record_less_denied_for_unknown_type?'s listed-read arm (#65) is the same
    # diagnostics-only shape — it labels a deny, it never decides. A new
    # caller must fit one of those shapes or use roles_ticking. (#65 cites
    # this comment as the safety condition; it is load-bearing, keep it true.)
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

    # A record-less target is allowed in one of two ways (#19, #65):
    #
    #   - an action in config.collection_read_actions asks scope_for — the
    #     id-narrowed query the list renders from — so the gate opens exactly
    #     when the subject's list would show records, full_access included.
    #     Gate and list agree by construction; an empty list (no grant, or a
    #     grant whose record was destroyed) is a deny, fail-closed.
    #   - any other action needs a scoped grant whose role EXPLICITLY ticks
    #     the key. scope_for then narrows the collection to the granted records.
    #
    # Without this, the two halves of the per-record feature contradict each
    # other: the gate turns a scoped-only subject away from their index, and
    # the org-wide grant that gets them past it makes scope_for return every
    # record.
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
    # Binds by TYPE (#50). The target names no record, but the controller can
    # name the type its collection lists via current_scope_model (record when
    # it is a Class — the allowed_to?(:index, Report) form — else the model:
    # kwarg the Guard threads). resource_type filters the grant to that type,
    # normalized through base_class exactly as scope_for does, so "a Report
    # grant" cannot open a Documents gate. UNKNOWN type ⇒ this branch does not
    # fire (fail-closed): before #50 an unbound grant of any type opened every
    # record-less gate, and for a key with no list side (#create) that let a
    # Report-scoped subject create Documents — a live escalation, not a
    # cosmetic empty list. A loud, documented deny is the safe direction.
    #
    # full_access and the two arms (#65): the read arm honors a scoped
    # full_access grant because scope_for's answer is DERIVED FROM RECORD IDS —
    # which records the subject holds, joined against the live table — the one
    # shape roles_granting's safety condition names as safe. The non-read arm
    # answers with a boolean off a type-bound match, strictly weaker (the id is
    # discarded), so full_access stays barred there: one scoped grant on one
    # Report must not create Reports. "Owner of Report #7" means full access to
    # Report #7 — and, since #65, to the lists that would show it. (#65 records
    # in full why a type-bound boolean over roles_granting is never the answer;
    # 029's R4 was withdrawn over exactly that.)
    #
    # TRUST NOTE: the declared type is trusted the way current_scope_record is.
    # A wrong current_scope_model plus a scoped full_access grant of the
    # declared type opens that controller's listed reads — review the
    # declaration like the record hook. Before #65 that misconfiguration
    # failed closed; the trade is deliberate and documented (README, #65 plan
    # KTD-5).
    #
    # Deliberately NOT memoized, unlike org_role. The memo there caches one
    # lookup keyed by subject, invalidated by RoleAssignment writes alone. This
    # predicate's answer derives from three tables (scoped assignments, roles,
    # role permissions) — four on the read arm, whose scope_for joins the model
    # table itself — so a memo would need invalidation hooks on all of them,
    # and a stale entry here is a stale ALLOW. Only record-less checks by
    # scoped-only subjects reach this line (org and full_access short-circuit
    # above), so the cost is one query — on the read arm an id-subquery EXISTS
    # against the model table — on a handful of nav-level checks per page, not
    # the per-row gate. Revisit if that ever shows up in a profile.
    def record_less_scoped_grant?(subject:, permission:, record:, model: nil)
      # R3a: the record-less shape test stays FIRST — a declared model never
      # rescues a non-record-less target. A host whose current_scope_record
      # wrongly returns params[:id] (a String) must still fail closed here, not
      # be allowed off a grant held over some other record.
      return false unless record.nil? || record.is_a?(Class)
      return false if sod_action?(permission)

      # The class form (allowed_to?(:index, Report)) carries the type as the
      # record; otherwise it comes from the model: hook. Unknown ⇒ deny (R3).
      type = record.is_a?(Class) ? record : model
      return false if type.nil?

      # Shape guard, mirroring R3a's on the record: a type that is not an
      # ActiveRecord model class (a String from a mis-declared
      # current_scope_model, a non-record-storing PORO passed to the class form
      # — the gem's own Scopeable Gadget is one) cannot name a base_class to
      # normalize by. Require an actual AR subclass, not just anything answering
      # base_class — a class whose base_class returns nil would still crash on
      # .name. Deny (fail-closed) rather than raise NoMethodError: a garbage
      # type is not a grant, and denying also preserves the pre-#50 boolean the
      # class form returned for a non-AR argument. This guard must stay ABOVE
      # the read arm — scope_for calls type.base_class and type.where, so a
      # non-AR type would 500 instead of denying. (#50 review, #65)
      #
      # ABSTRACT classes are excluded too (#65 review): ApplicationRecord
      # passes `< ActiveRecord::Base` but has no table, so the read arm's
      # scope_for would raise TableNotSpecified where the ticking arm's
      # resource_type match simply found nothing. An abstract class stores no
      # rows, so no scoped grant can name it — deny, don't 500.
      return false unless type.is_a?(Class) && type < ActiveRecord::Base && !type.abstract_class?

      if collection_read_action?(permission)
        scope_for(subject: subject, model: type, permission: permission).exists?
      else
        ScopedRoleAssignment
          .where(subject: subject, resource_type: type.base_class.name, role_id: roles_ticking(permission))
          .exists?
      end
    end

    # Would declaring current_scope_model have given this record-less deny a
    # chance? True only for the exact cell the #50 fail-closed default created:
    # a DECLARED collection action (record nil — the class form always carries
    # its type, so it never lands here), no declared model, not an SoD action
    # (those are refused whatever the type), and a scoped grant EXPLICITLY
    # ticking the key exists. Pure — reads only; decide labels the deny
    # :model_undeclared off this, changing no allow/deny.
    #
    # The role set follows the arm the deny came from (#65): a listed read
    # matches a full_access-INCLUSIVE set, because a declared type would honor
    # full_access there through scope_for — the label stays honest by saying
    # so. Off the read list the set stays roles_ticking: naming a full_access
    # grant :model_undeclared on #create would send the host to a fix that
    # fixes nothing. Diagnostics-only either way — this labels a deny, it
    # never decides (the scoped_grant_exists? shape, named in roles_granting's
    # safety comment) — and it runs without a model, so it cannot check record
    # liveness: a grant on a destroyed record makes "declare the model and
    # this allows" false, which is why the nudge says "may fix", never
    # promises.
    def record_less_denied_for_unknown_type?(subject:, permission:, record:, model:)
      return false unless record.nil? && model.nil?
      return false if sod_action?(permission)

      roles = collection_read_action?(permission) ? roles_granting(permission) : roles_ticking(permission)
      ScopedRoleAssignment.where(subject: subject, role_id: roles).exists?
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

    # An action whose record-less gate derives from the scoped list (#65).
    # Matched like sod_action?: the action segment of the key against a config
    # list (config.collection_read_actions normalizes to strings on write).
    def collection_read_action?(permission)
      CurrentScope.config.collection_read_actions.include?(permission.split("#").last)
    end
  end
end
