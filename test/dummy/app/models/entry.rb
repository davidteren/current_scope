# Child of a business-primary-key parent. The FK holds Ledger.code, not the
# surrogate id. A grant on the parent must list these rows, not a collision row.
class Entry < ApplicationRecord
  belongs_to :ledger, optional: true, foreign_key: :ledger_id, primary_key: :code
  current_scope_parent :ledger
end
