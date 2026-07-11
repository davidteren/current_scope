# Tableless test double: scopeable, but defines its own current_scope_label to
# prove a host override beats the mixin default.
class Gadget
  include ActiveModel::Model
  include CurrentScope::Scopeable

  attr_accessor :id

  def current_scope_label
    "custom"
  end
end
