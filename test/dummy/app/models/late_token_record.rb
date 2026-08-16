# Loaded only when a test names it, so rebuild-on-miss can be pinned.
class LateTokenRecord < ApplicationRecord
  self.table_name = "folders"

  def self.polymorphic_name = "late_tokens"
end
