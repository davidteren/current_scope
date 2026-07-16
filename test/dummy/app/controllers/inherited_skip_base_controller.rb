# The #62 fail-open, step one: a ROUTED base controller with a bare skip —
# no `only:`, nothing re-asserted downstream. The skip is legitimate here
# (say, a public landing action), but it silently inherits into every
# subclass. Deliberately NOT abstract: an abstract base is never routed and
# never a grid row, and the bug only bites on controllers the grid shows as
# grantable.
class InheritedSkipBaseController < ApplicationController
  include CurrentScope::Guard

  skip_before_action :current_scope_check!, raise: false

  def index
    render plain: "inherited_skip_base#index"
  end
end
