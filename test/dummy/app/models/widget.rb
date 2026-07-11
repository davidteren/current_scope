# Tableless test double: opts into the scoped-role picker via the Scopeable
# mixin and relies on the mixin's default current_scope_label. The registry
# and label behaviour need no table.
class Widget
  include ActiveModel::Model
  include CurrentScope::Scopeable

  attr_accessor :id
end
