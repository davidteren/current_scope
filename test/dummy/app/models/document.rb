# STI base — a scoped grant on any Document (or subclass) stores
# resource_type = "Document" (the base_class), which is what scope_for must
# query even when asked about a subclass.
class Document < ApplicationRecord
  # #183: an STI base, so the suite can prove a declaration on a SUBCLASS is the
  # one that governs a grant on its records — the polymorphic token stores the
  # base class either way, which is exactly the trap.
  include CurrentScope::GrantableRoles
end
