# STI base — a scoped grant on any Document (or subclass) stores
# resource_type = "Document" (the base_class), which is what scope_for must
# query even when asked about a subclass.
class Document < ApplicationRecord
end
