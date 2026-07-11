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

    # A real actor stands behind a distinct effective subject (act-as). Read
    # from the ambient context directly, so the gate holds even where the
    # Permissions helpers are not mixed in.
    def current_scope_impersonating?
      user = CurrentScope::Current.user
      user.present? && CurrentScope::Current.actor != user
    end

    # Denials render forbidden and surface the machine-readable reason on the
    # response so refusals are diagnosable by clients and tests.
    def current_scope_denied(exception = nil)
      reason = exception.respond_to?(:reason) ? exception.reason : nil
      response.headers["X-Current-Scope-Reason"] = reason.to_s if reason
      head :forbidden
    end
  end
end
