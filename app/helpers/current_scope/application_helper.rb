module CurrentScope
  module ApplicationHelper
    # Best-effort human label for any host subject/resource. Prefers a record's
    # own current_scope_label (the Scopeable mixin gives every pickable model
    # one) so the label a model declares is the label shown everywhere — the
    # picker, the chips, and the ledger (see Event.label_for) all agree.
    def current_scope_label(record)
      return record.current_scope_label if record.respond_to?(:current_scope_label)

      name = record.try(:name) || record.try(:email) || record.try(:title)
      name || "#{record.class.name} ##{record.id}"
    end

    # Best-effort label for a stored GID string (event actor/subject). Falls
    # back to the raw GID when the record is gone — the ledger outlives the
    # identities it names.
    def current_scope_gid_label(gid)
      record = GlobalID::Locator.locate(gid)
      record ? current_scope_label(record) : gid
    end
  end
end
