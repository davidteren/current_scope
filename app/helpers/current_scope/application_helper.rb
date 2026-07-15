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
    # when unset, when it resolves to a blank value, or when it fails.
    #
    # subject_label is arbitrary host code running once per row on the admin's
    # main tool for granting and reviewing roles. One subject with incomplete
    # data (a Proc doing `u.email.upcase` on a subject whose email is nil) must
    # not take the whole page down — the same intent the holder-label helpers
    # below already encode for stale polymorphic types. A failure here costs one
    # label; a raise costs the page.
    def configured_subject_label(subject)
      label = CurrentScope.config.subject_label
      return if label.nil?

      if label.respond_to?(:call)
        resolve_subject_label(label) { label.call(subject) }
      elsif subject.respond_to?(label)
        resolve_subject_label(label) { subject.public_send(label) }
      else
        # Not a mistake we can render around: this config does nothing for EVERY
        # subject, silently, which is why it needs saying out loud once.
        CurrentScope::ApplicationHelper.warn_unknown_subject_label_once(label)
        nil
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

    private

    # ponytail: display fallback only — NEVER a decision path. This rescue makes
    # a label degrade instead of erroring; the resolver, Guard and catalog are
    # untouched, so it relaxes no fail-closed guarantee. (The same `rescue
    # StandardError` on a decision path would be a fail-open bug.)
    #
    # StandardError rather than the NameError family the holder helpers catch:
    # those wrap OUR call into a known-shaped record, while this runs a host's
    # arbitrary Proc, which can raise anything. Catching only NameError would
    # fix the reported NoMethodError and leave the same page-down bug for a
    # differently-broken Proc.
    #
    # nil rejoins the existing "resolved blank -> default chain" path in
    # current_scope_subject_label, so no caller learns a new branch.
    def resolve_subject_label(label)
      yield.to_s.presence
    rescue StandardError => e
      CurrentScope::ApplicationHelper.warn_subject_label_raised_once(label, e)
      nil
    end

    class << self
      # Warn ONCE per (reason, label): a misconfigured subject_label is the same
      # mistake on every row, so one line is a signal and one-per-subject is
      # noise the admin will scroll past. Keyed by the label value, so changing
      # the config in dev warns again for the new value.
      #
      # Always-on rather than behind a warn_on_* flag (cf. warn_on_nil_sod_record,
      # which defaults off because a nil record is often legitimate): a label the
      # subject can't answer, or one that raises, is unambiguously a mistake.
      # Mirrors Event.warn_missing_events_table_once.
      def warn_unknown_subject_label_once(label)
        return unless new_subject_label_warning?(:unknown, label)

        Rails.logger&.warn(
          "[CurrentScope] config.subject_label is #{label.inspect}, but subjects do not respond to " \
          "it — every subject is falling back to the default label, so this config currently does " \
          "nothing. Set it to a method the subject responds to (e.g. :email), a Proc, or nil."
        )
      end

      def warn_subject_label_raised_once(label, error)
        return unless new_subject_label_warning?(:raised, label)

        Rails.logger&.warn(
          "[CurrentScope] config.subject_label raised #{error.class}: #{error.message} — that " \
          "subject fell back to the default label rather than erroring the page. A subject_label " \
          "must be total: it runs for every subject, including ones with nil or blank attributes."
        )
      end

      private

      def new_subject_label_warning?(reason, label)
        (@subject_label_warnings ||= Set.new).add?([ reason, label ])
      end
    end
  end
end
