CurrentScope.configure do |config|
  # --- Retrofitting an existing app? Start here ---------------------------
  #
  # This engine is fail-closed: once the gate is mounted, anything not granted
  # is denied. In an app that already has users and traffic, that means your
  # controller suite goes RED and your users get 403s the moment you mount it —
  # not because anything is misconfigured, but because no grants exist yet.
  #
  # So don't cut over blind. Run in report mode first:
  #
  #   config.enforcement = :report
  #
  # The gate then LOGS what it would have denied and lets the request through.
  # Exercise the app (or run your suite), then read the gaps back out — each row
  # names a subject and the permission they were missing:
  #
  #   bin/rails current_scope:report
  #
  # That list IS your grant-seeding work. Seed the roles it names, watch the
  # would_deny rows stop appearing, then flip to :enforce. Reversible at every
  # step — it's one line back.
  #
  # Report mode is an ADOPTION ramp, not a way to run in production. It relaxes
  # exactly one thing: "nobody has granted this yet". A separation-of-duties
  # veto still refuses, and the management console is never opened by it.
  #
  # config.enforcement = :enforce   # :enforce (default) | :report
  # ------------------------------------------------------------------------

  # What the opt-in GatingTripwire mixin does when it catches an action that
  # completed WITHOUT running the gate. :raise fails loudly (CI goes red);
  # :warn logs once per controller#action and lets the response through, so a
  # real app can inventory its ungated surface without 500ing. There is no
  # :off — not including CurrentScope::GatingTripwire is off.
  # config.gating_tripwire = Rails.env.local? ? :raise : :warn

  # Controller method that returns the authenticated subject.
  # config.user_method = :current_user

  # Class whose instances hold roles, used by the management UI.
  # config.subject_class = "User"

  # How a subject is identified in the management UI (an id is meaningless with
  # UUID keys). A Symbol names a method; a Proc takes the subject. Defaults to a
  # best-effort label (current_scope_label, else name/email/title, else id).
  # config.subject_label = :email
  # config.subject_label = ->(u) { "#{u.first_name} #{u.last_name}" }

  # Fold the role-editor grid's action columns. Default = CRUD (new/edit hide
  # into create/update; index+show read as one). Set to nil to show every raw
  # action as its own column.
  # config.permission_grid_groups = { "read" => %w[index show], "create" => %w[new create],
  #                                   "update" => %w[edit update], "destroy" => %w[destroy] }

  # Action names whose record-less gate derives its answer from the scoped
  # list: for these, "may they open this list?" is answered by the same
  # id-narrowed query scope_for renders from, so a scoped full_access role
  # ("Owner of Report #7") opens exactly the collections that would show it
  # records — gate and list agree by construction. Matched on the action
  # segment of the key, like sod_actions. Default ["index"]; set [] to
  # restore the 0.2 behavior (scoped full_access opens no record-less gate).
  #
  # LIST-NARROWING READS ONLY: the safety of honoring full_access here comes
  # from the answer being derived from record ids, so it is only sound for
  # actions with a list side. Never name a mutating action ("create",
  # "destroy_all") — that would hand a scoped full_access holder the action
  # on every record of the type off a grant on one record. Custom read
  # actions (export, search) are the intended additions. The declared
  # current_scope_model is trusted like current_scope_record: review both.
  # config.collection_read_actions = %w[index]

  # --- Impersonation (act-as) ---------------------------------------------
  # These three knobs layer, in this order:
  #
  #   1. actor_method                        — turns impersonation ON.
  #   2. allow_mutations_while_impersonating — the read-only gate runs FIRST.
  #   3. sod_identity                        — only observable once a mutation
  #                                            is allowed through (or on a
  #                                            GET-listed sod_action).
  #
  # Controller method returning the REAL actor while impersonating. Leave unset
  # when no one impersonates — actor then equals the subject, so attribution
  # reads current_scope_actor with no nil branch, and sod_identity below has no
  # effect. See the "Impersonation (act-as)" section of the README.
  # config.actor_method = :true_user

  # false (default): an impersonated session is read-only — every non-GET/HEAD
  # request is denied, INCLUDING the engine's management UI. Your
  # stop-impersonation, sign-out, and sign-in endpoints must opt out with
  # skip_before_action :current_scope_mutation_guard!, or impersonation (and
  # sign-in) can never clear it.
  # config.allow_mutations_while_impersonating = false

  # Which identities the separation-of-duties veto weighs. :either (default)
  # also vetoes a record the REAL actor initiated while impersonating, so
  # impersonation can never approve your own record. :subject weighs only the
  # effective subject. Identical when not impersonating.
  # config.sod_identity = :either
  # ------------------------------------------------------------------------

  # Separation of duties is OPT-IN — empty by default. List the actions a
  # record's initiator can never perform on their own record (four-eyes).
  # Deliberately NOT editable in the UI. Records reached by these actions must
  # define current_scope_initiator (return nil to exempt a record type) — the
  # resolver raises if the hook is missing. Leave commented for RBAC-only apps.
  # config.sod_actions = %w[approve]

  # Audit ledger — tri-state: false | true (default) | :strict.
  #   false   — no audit rows recorded.
  #   true    — record every authorization change; if the events table hasn't
  #             been migrated yet, degrade gracefully (skip + warn once).
  #   :strict — a missing events table RAISES (rolling the mutation back), so an
  #             audit-mandatory app never commits an unaudited change.
  # config.audit = true

  # --- Dev diagnostics -----------------------------------------------------
  # Four failure modes this engine has that are SILENT, and silent in the bad
  # direction — the thing going wrong looks exactly like the thing going right.
  # All four are LOG-ONLY (no decision, exception, header, or audit row changes)
  # and all four default ON in development and test, OFF in production.
  #
  # They are listed here rather than left to the docs on purpose: a named flag in
  # your initializer is how you learn the failure mode exists at all.

  # The SoD veto was SKIPPED because the gate had no record — an SoD member
  # action whose current_scope_record returned nil (or was never declared). The
  # request was ALLOWED, and a skipped veto looks identical to a veto that
  # passed. The gem's #1 foot-gun.
  # config.warn_on_nil_sod_record = Rails.env.local?

  # Denied "no_grant", but the subject holds a scoped grant that WOULD have
  # applied — and the controller declares no current_scope_record, so the gate
  # had no record to apply it to. A member action that forgot its hook: it fails
  # closed (correctly), but the 403 is indistinguishable from "never granted", so
  # you go and stare at the grants, which are fine.
  # config.warn_on_inert_scoped_grant = Rails.env.local?

  # Short-form allowed_to?(:show, record) derived a DIFFERENT key than the gate
  # on the current controller enforces (the namespaced/custom-named controller
  # foot-gun): a link that 403s, or a hidden one that would have worked. A hint,
  # not an accusation — asking about another resource derives a different key too,
  # and that's correct — so it warns once per site and names both readings.
  # config.warn_on_cross_controller_derivation = Rails.env.local?

  # Denied "model_undeclared": a collection action declared with
  # `current_scope_record = nil` on a controller that names no
  # current_scope_model, while the subject holds a scoped grant ticking the
  # key. The gate had no type to bind that grant to, so it failed closed —
  # correctly, but the fix is one line: `def current_scope_model = TheType`.
  # config.warn_on_undeclared_collection_model = Rails.env.local?
  # ------------------------------------------------------------------------

  # Controller paths (regexps) excluded from the permission grid. Excluded
  # controllers can't be granted, so they must also skip the gate with
  # skip_before_action :current_scope_check! — Guard raises otherwise.
  # config.excluded_controllers += [%r{\Awebhooks/}]

  # Controller the management UI inherits from (for host auth + before_actions).
  # config.parent_controller = "::ApplicationController"
end
