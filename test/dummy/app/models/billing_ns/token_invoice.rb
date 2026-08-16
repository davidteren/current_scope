# Namespaced resource with Rails' shortened token (store_full_class_name =
# false). polymorphic_name is "TokenInvoice", which is not a top-level
# constant, so Rails cannot reverse it. The registry must.
module BillingNs
  class TokenInvoice < ApplicationRecord
    self.table_name = "folders"
    self.store_full_class_name = false
  end
end
