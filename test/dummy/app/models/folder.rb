# A real ActiveRecord model that opts into the scoped-role picker via the
# Scopeable mixin AND defines its own current_scope_label. The label is a
# computed Ruby method (no dedicated label column), which is exactly why the
# picker's record search filters in Ruby rather than with SQL LIKE.
class Folder < ApplicationRecord
  include CurrentScope::Scopeable

  def current_scope_label = name
end
