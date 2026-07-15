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
  # Exercise the app (or run your suite), then read the gaps back out of the
  # ledger — each row names a subject and the permission they were missing:
  #
  #   CurrentScope::Event.where(event: "access.would_deny")
  #                      .pluck(:subject, :details)
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

  # Dev/test aid: log a nudge when an SoD action is ALLOWED but was gated with a
  # nil record — i.e. the SoD veto was silently skipped because
  # current_scope_record returned nil on a member action. Off by default; never
  # changes behavior.
  # config.warn_on_nil_sod_record = false

  # Controller paths (regexps) excluded from the permission grid. Excluded
  # controllers can't be granted, so they must also skip the gate with
  # skip_before_action :current_scope_check! — Guard raises otherwise.
  # config.excluded_controllers += [%r{\Awebhooks/}]

  # Controller the management UI inherits from (for host auth + before_actions).
  # config.parent_controller = "::ApplicationController"
end
