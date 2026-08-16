# Stable custom-token resource for #155. Shares the folders table so no extra
# migration is needed. polymorphic_name is not a constant, so Rails cannot
# reverse it and collection queries that still use base_class.name miss grants.
class TokenDocument < ApplicationRecord
  self.table_name = "folders"

  def self.polymorphic_name = "token_docs"
end
