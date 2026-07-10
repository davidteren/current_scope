module CurrentScope
  # Include CurrentScope::Scopeable to make a model pickable in the scoped-role
  # assignment UI's type dropdown. BROWSE-ONLY — it does NOT gate access: any
  # model is still a valid GlobalID scoped-role target whether or not it opts in.
  #
  # The `included` hook self-registers the class by NAME (stored as a string and
  # resolved lazily) so dev-mode class reloading never pins a stale constant;
  # the engine rebuilds the registry on every to_prepare.
  module Scopeable
    extend ActiveSupport::Concern

    included do
      CurrentScope.register_scopeable(name) if name
    end

    # Default label for the picker. Defined as an ordinary instance method so a
    # host that provides its own current_scope_label simply overrides it — the
    # host class sits ahead of this module in the ancestor chain.
    def current_scope_label
      "#{model_name.human} ##{id}"
    end
  end
end
