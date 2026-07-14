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

      # A configured label that resolves to nil/blank (e.g. :email on a subject
      # with no email yet) must not render as an empty row — fall through to the
      # default human-identifier chain rather than showing "".
      configured = configured_subject_label(subject)
      return configured if configured

      # Default: a subject is a person, so prefer human identifiers over a
      # generic "Class #id" — including when the model includes Scopeable, whose
      # current_scope_label is id-based. Covers `email` and Rails 8 auth's
      # `email_address`. Config overrides this entirely.
      full_name = [ subject.try(:first_name), subject.try(:last_name) ].compact.join(" ").presence
      # .presence on each identifier: a stored empty/whitespace email ("") is
      # truthy in Ruby and would otherwise short-circuit to a blank label.
      subject.try(:email).presence || subject.try(:email_address).presence ||
        subject.try(:name).presence || full_name || current_scope_label(subject)
    end

    # The configured subject_label (Symbol or Proc) applied to a subject, or nil
    # when unset or when it resolves to a blank value.
    def configured_subject_label(subject)
      label = CurrentScope.config.subject_label
      if label.respond_to?(:call)
        label.call(subject).to_s.presence
      elsif label && subject.respond_to?(label)
        subject.public_send(label).to_s.presence
      end
    end

    # Members-list labels that survive a stale/renamed polymorphic type — a
    # removed subject or resource class must not 500 the page; fall back to
    # "Type #id" the way the audit ledger does.
    def current_scope_holder_subject_label(assignment)
      current_scope_subject_label(assignment.subject)
    rescue NameError, ActiveRecord::RecordNotFound
      "#{assignment.subject_type} ##{assignment.subject_id}"
    end

    def current_scope_holder_resource_label(scoped_assignment)
      current_scope_label(scoped_assignment.resource)
    rescue NameError, ActiveRecord::RecordNotFound
      "#{scoped_assignment.resource_type} ##{scoped_assignment.resource_id}"
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
