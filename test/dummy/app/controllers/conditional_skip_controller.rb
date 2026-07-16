# The conditional-skip residual shape: a normally gated controller where ONE
# action opts out via `only:`. #index is ungated (a deliberate public listing);
# #show still runs current_scope_check!. Detection must read the condition —
# flagging the whole controller as fail-open would be a false positive on #show.
class ConditionalSkipController < ApplicationController
  include CurrentScope::Guard

  skip_before_action :current_scope_check!, only: :index, raise: false

  def index
    render plain: "conditional_skip#index"
  end

  def show
    render plain: "conditional_skip#show"
  end
end
