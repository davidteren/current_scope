# The public "Reset sandbox now" control (the honesty banner's button). Enqueues
# SandboxResetJob so a visitor can restore clean props on demand — itself a nice
# authorization-as-data beat: resetting is a plain POST anyone may make, gated
# only by a rate limit, not a role. Excluded from the permission grid and
# gate-skipped so the role-less Visitor can reach it (a narrative surface, like
# the lobby).
class SandboxController < ApplicationController
  skip_before_action :current_scope_check!
  # ponytail: a dedicated in-process limiter store. The demo runs single-process
  # (Solid Queue lives inside Puma), so an in-process counter IS the shared
  # counter — and it keeps limiting even where the app cache is a null store (as
  # in tests, unlike the Rails.cache-backed sessions/passwords precedent). Move
  # to Rails.cache if this ever scales past one process.
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new
  # Sandbox abuse bound: a full DB rewrite is expensive, so cap it hard.
  rate_limit to: 5, within: 1.minute, only: :reset, store: RATE_LIMIT_STORE,
    with: -> { redirect_back fallback_location: root_path, alert: "A reset is already in flight — try again shortly." }

  def reset
    SandboxResetJob.perform_later
    redirect_back fallback_location: root_path, notice: "Resetting the sandbox to seed state…"
  end
end
