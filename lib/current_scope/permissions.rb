module CurrentScope
  # The portable authorization mixin. Works anywhere — controllers, views,
  # components, POROs — because the subject comes from the ambient
  # CurrentScope::Current context rather than being threaded through calls.
  # Everything delegates to the one resolver, so a view can never disagree
  # with the controller gate.
  #
  #   allowed_to?(:approve, report)          # key derived from the record
  #   allowed_to?(:create, Report)           # class works for collection actions
  #   allowed_to?("admin/reports#approve")   # explicit full key
  #   allowed_to?(:index, controller: "reports")
  module Permissions
    def allowed_to?(action, record = nil, controller: nil)
      controller ||= controller_path if respond_to?(:controller_path)
      CurrentScope.allowed?(action, subject: current_scope_user, record: record,
        controller_path: controller, actor: current_scope_actor,
        model: ambient_collection_model(action, controller))
    end

    # The list-side companion to allowed_to?: "which records of `model` may the
    # effective subject act on?". Same grants and keys as the gate, resolved
    # fail-closed (nil subject / no grant → none) — but scope_for answers ROW
    # MEMBERSHIP only, never action reachability. Gate checks that sit on top
    # of the grant do not filter this list:
    #   - the separation-of-duties veto — for an SoD-listed action the list CAN
    #     include the subject's own initiated records, which the per-record
    #     gate then refuses;
    #   - the impersonation mutation gate — a REQUEST-level guard, not a
    #     per-record one: it blocks any non-GET/HEAD request while
    #     impersonating, collection actions included;
    #   - record-less gate paths (a hookless controller's NO_RECORD decision).
    # So a listed row can still 403 when acted on. Per-row affordances for
    # SoD-listed actions must check allowed_to?(action, record); mutation
    # affordances while impersonating should key off impersonating?.
    # Returns a chainable relation (.where/.order/.page on it). `permission`
    # defaults to the model's index context and accepts a bare action or a
    # full key.
    #
    #   scope_for(Project)                 # projects#index — what a list shows
    #   scope_for(Report, permission: :approve)
    #   scope_for(Report, permission: "admin/reports#approve")
    def scope_for(model, permission: nil)
      # Derive the key exactly like allowed_to? — including controller_path, so a
      # namespaced controller's list resolves to the same key as its gate
      # (admin/reports#index, not reports#index) and the two never drift.
      controller = controller_path if respond_to?(:controller_path)
      CurrentScope.scope_for(
        subject: current_scope_user,
        model: model,
        permission: CurrentScope.permission_key(permission || :index, record: model, controller_path: controller)
      )
    end

    # The type the controller handling THIS request declared for its collection
    # actions (#50), so a bare allowed_to?(:index) in its own view binds the
    # record-less gate the same way the gate did — otherwise the fix would hide
    # a link the gate allows. Only for the request's OWN controller: a
    # cross-controller question resolves a key about a different controller than
    # the ambient type answers, so it gets nil and falls to the fail-closed
    # default — the class form allowed_to?(:index, Report) is how you ask about
    # another controller, and it binds from its argument (R5). (KTD-6)
    #
    def current_scope_user
      CurrentScope::Current.user
    end

    # The REAL actor behind the request (never nil when a subject is set — it
    # falls back to the subject). Read this for attribution, not Current.
    def current_scope_actor
      CurrentScope::Current.actor
    end

    # True only while a distinct real actor stands behind the effective
    # subject (act-as). Views use it as the read-only-state signal. Delegates
    # to the one definition on Current, shared with the mutation guard.
    def impersonating?
      CurrentScope::Current.impersonating?
    end

    private

    # Internal binding for gate/view agreement (#50 KTD-6) — not host API.
    # Private so it does not appear in controller action_methods. Matches on
    # the KEY's controller, not just the controller: kwarg: a full
    # "reports#index" key from a projects view must not borrow the projects
    # ambient. A bare action uses the resolved controller. (#50 review, cubic)
    def ambient_collection_model(action, controller)
      key_controller = action.to_s.include?("#") ? action.to_s.split("#").first : controller
      return nil unless key_controller && key_controller == CurrentScope::Current.collection_model_path

      CurrentScope::Current.collection_model
    end
  end
end
