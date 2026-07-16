module CurrentScope
  # The read-only-while-impersonating gate. A SEPARATE before_action from the
  # permission check, on purpose: the engine's management UI does
  # skip_before_action :current_scope_check!, and a gate folded into that check
  # would exempt the highest-value surface (grid/role/grant mutations). Guard
  # includes this so the gate runs BEFORE the permission check; the engine
  # ApplicationController includes it directly so skipping the permission check
  # never skips the gate.
  #
  # An impersonated session is read-only by default: any non-GET/HEAD request is
  # denied while a real actor stands behind a different effective subject. The
  # endpoints that MUST run while impersonating — a host's stop-impersonation,
  # sign-out, and sign-in actions — opt out with:
  #
  #   skip_before_action :current_scope_mutation_guard!
  #
  # (Method spoofing is not a concern: Rack::MethodOverride only upgrades POST,
  # and mutating actions are verb-pinned by routing.)
  module MutationGuard
    extend ActiveSupport::Concern

    included do
      before_action :current_scope_mutation_guard!
      rescue_from CurrentScope::AccessDenied, with: :current_scope_denied
    end

    private

    def current_scope_mutation_guard!
      return if request.get? || request.head?
      return if CurrentScope.config.allow_mutations_while_impersonating
      return unless current_scope_impersonating?

      raise CurrentScope::AccessDenied.new(
        "#{controller_path}##{action_name}", reason: :impersonation_gate
      )
    end

    # A real actor stands behind a distinct effective subject (act-as).
    # Delegates to the one definition on Current (not the Permissions mixin,
    # which isn't mixed in everywhere this gate runs) so the gate and the
    # view-level read-only signal share a single authoritative predicate.
    def current_scope_impersonating?
      CurrentScope::Current.impersonating?
    end

    # Denials render forbidden and surface the machine-readable reason on the
    # response so refusals are diagnosable by clients and tests.
    #
    # The ONLY place the reason header is written. Every denial in the gem —
    # the Guard's, this gate's, and the engine's own front door — raises
    # AccessDenied and lands here, so a denial cannot exist that forgets the
    # header. (The engine's front door used to render its own `head :forbidden`
    # and was exactly that denial: no header, no body. #23.)
    def current_scope_denied(exception = nil)
      reason = exception.respond_to?(:reason) ? exception.reason : nil
      response.headers["X-Current-Scope-Reason"] = reason.to_s if reason
      current_scope_render_denied(reason)
    end

    # How a denial renders — the one part a controller may vary. Default: a
    # bodyless 403, which is what a host app's denial has always been and must
    # stay. This runs inside HOST controllers (Guard mixes it in), so rendering
    # a body here would push an engine-shaped response into an app that never
    # asked for one, with no layout or view to render it in. The engine's own
    # controller overrides this to explain itself; nothing else should.
    #
    # `current_scope_`-prefixed like every other method this concern mixes into
    # a host controller (current_scope_check!, current_scope_denied,
    # current_scope_mutation_guard!, current_scope_record). A bare
    # `render_access_denied` is a name a host app could plausibly already have,
    # and we would silently call theirs.
    #
    # Takes the reason: an overrider that renders a body needs to know WHICH
    # denial it is answering, or it will explain the wrong one.
    def current_scope_render_denied(_reason = nil)
      head :forbidden
    end
  end
end
