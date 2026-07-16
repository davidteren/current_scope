# The #62 fail-open, step two: inherits the base's bare skip and adds NOTHING.
# Its action is routed, so the grid shows it as grantable — but the gate never
# runs here, so ticking that box is ticking nothing.
class InheritedSkipChildController < InheritedSkipBaseController
  def index
    render plain: "inherited_skip_child#index"
  end
end
