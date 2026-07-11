# The public lobby. A role-less Visitor is fail-closed everywhere else, so this
# ungated landing is where it lands and steps into a persona. Excluded from the
# catalog, so it skips the permission gate.
class HomeController < ApplicationController
  skip_before_action :current_scope_check!

  def index
  end
end
