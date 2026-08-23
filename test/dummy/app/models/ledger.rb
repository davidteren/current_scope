# Declares a BUSINESS primary key while keeping the surrogate `id` column, so
# the suite can tell "keyed on the declared primary key" from "keyed on id".
# A scoped grant stores `code` (Rails' polymorphic writer reads klass.primary_key).
class Ledger < ApplicationRecord
  self.primary_key = "code"

  has_many :entries, foreign_key: :ledger_id, primary_key: :code, dependent: :nullify
end
