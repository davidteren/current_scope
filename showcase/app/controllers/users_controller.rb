# The read-only "who can do what" roster (U13). The engine's management UI is
# full-access gated — a Visitor or Member-acting persona gets 403 there — so
# this surface is the showcase's OWN mirror of the authorization model: visible
# to EVERYONE, with the mutating controls linking INTO the gated engine UI and
# shown only to full-access personas.
#
# Like act_as and the walkthrough, this narrative surface skips the fail-closed
# gate (an excluded controller that stayed gated would raise) and is excluded
# from the permission grid. It is GET-only, so the read-only-while-impersonating
# mutation guard is a no-op here and needs no exemption.
class UsersController < ApplicationController
  skip_before_action :current_scope_check!

  # Personas the live-grid beat scripts, resolved by seeded email. Nil-guarded
  # like the walkthrough: a sandbox reset can delete them, and the beat panel
  # simply hides rather than 500ing.
  BEAT_OWNER_EMAIL    = "owner@example.com"
  BEAT_APPROVER_EMAIL = "expenses.approver@example.com"
  BEAT_ROLE_NAME      = "Expenses Approver"

  def index
    @users = User.order(:email_address)
    # Preload the org role (one per subject) and scoped roles per user so the
    # roster doesn't N+1 across every row.
    @org_roles = CurrentScope::RoleAssignment.where(subject_type: "User")
                   .includes(:role).index_by(&:subject_id)
    @scoped_roles = CurrentScope::ScopedRoleAssignment.where(subject_type: "User")
                      .includes(:role, :resource).group_by(&:subject_id)

    return unless CurrentScope.resolver.full_access?(current_scope_user)

    @beat_owner    = User.find_by(email_address: BEAT_OWNER_EMAIL)
    @beat_approver = User.find_by(email_address: BEAT_APPROVER_EMAIL)
    @beat_role     = CurrentScope::Role.find_by(name: BEAT_ROLE_NAME)
  end
end
