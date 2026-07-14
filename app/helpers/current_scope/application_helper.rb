module CurrentScope
  module ApplicationHelper
    # Best-effort human label for any host subject/resource. Prefers a record's
    # own current_scope_label (the Scopeable mixin gives every pickable model
    # one) so the label a model declares is the label shown everywhere — the
    # picker, the chips, and the ledger (see Event.label_for) all agree.
    def current_scope_label(record)
      return "(none)" if record.nil?
      return record.current_scope_label if record.respond_to?(:current_scope_label)

      name = record.try(:name) || record.try(:email) || record.try(:title)
      name || "#{record.class.name} ##{record.id}"
    end

    # Human label for a subject (user/account), honouring config.subject_label
    # so a host on UUID keys can show email or a full name instead of an
    # opaque id. Falls back to the best-effort current_scope_label.
    def current_scope_subject_label(subject)
      return "(none)" if subject.nil?

      label = CurrentScope.config.subject_label
      if label.respond_to?(:call)
        label.call(subject).to_s
      elsif label && subject.respond_to?(label)
        subject.public_send(label).to_s
      else
        current_scope_label(subject)
      end
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
