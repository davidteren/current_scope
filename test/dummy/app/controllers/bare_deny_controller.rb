# #39: raise AccessDenied with no Guard/MutationGuard rescue_from, so the
# engine's rescue_responses mapping (not current_scope_denied) classifies it.
# No Context include — we only need an unrescued raise past the controller.
class BareDenyController < ActionController::Base
  def deny
    raise CurrentScope::AccessDenied.new(
      "bare_deny#deny",
      reason: :no_grant,
      permission: "bare_deny#deny"
    )
  end
end
