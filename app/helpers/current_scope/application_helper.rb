module CurrentScope
  module ApplicationHelper
    # Best-effort human label for any host subject/resource. Delegates to the
    # one shared chain (CurrentScope.label_for) — the same definition the audit
    # ledger denormalizes (see Event.label_for), so the picker, the chips, and
    # the ledger agree by construction, not by parallel maintenance.
    def current_scope_label(record)
      return "(none)" if record.nil?

      CurrentScope.label_for(record)
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
      return resolve_subject_label(label) { label.call(subject) } if label.respond_to?(:call)

      # Only a Symbol or String names a method. Checked BEFORE respond_to?,
      # which raises TypeError on anything else ("false is not a symbol nor a
      # string") — and that raise would land outside the rescue below and 500
      # the page, which is the bug this method exists to prevent, reached
      # through a different door.
      unless label.is_a?(Symbol) || label.is_a?(String)
        CurrentScope::ApplicationHelper.warn_unusable_subject_label_once(label)
        return
      end

      if subject.respond_to?(label)
        resolve_subject_label(label) { subject.public_send(label) }
      else
        # Not a mistake we can render around: this config does nothing for EVERY
        # subject, silently, which is why it needs saying out loud once.
        CurrentScope::ApplicationHelper.warn_unknown_subject_label_once(label)
        nil
      end
    rescue StandardError => e
      # Last resort, and the reason it exists: every branch above calls a method
      # ON the host's config value to classify it — `nil?`, `respond_to?`,
      # `is_a?`. A pathological value breaks the classification itself, before
      # any specific guard can classify it, so the guards cannot be where this
      # is caught. A BasicObject has no #nil?; a delegator can raise from
      # respond_to?.
      #
      # Deliberately does NOT touch `label`: it is the thing that just proved it
      # cannot be touched. The warning is keyed off the error alone.
      CurrentScope::ApplicationHelper.warn_subject_label_broken_once(e)
      nil
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
      #
      # Says "this subject" rather than "subjects": under STI some subclasses may
      # answer and others not, and warn-once means the first non-responder would
      # otherwise speak for all of them.
      def warn_unknown_subject_label_once(label)
        return unless new_subject_label_warning?(:unknown, label)

        Rails.logger&.warn(
          "[CurrentScope] config.subject_label is #{label.inspect}, but this subject does not " \
          "respond to it — it is falling back to the default label. If no subject responds to it, " \
          "this config does nothing. Set it to a method the subject responds to (e.g. :email), a " \
          "Proc, or nil."
        )
      end

      # Not a Symbol, String, Proc, or nil — so it can't name a method and can't
      # be called. Reports the TYPE, not the value: this is the one warning whose
      # subject is an arbitrary host object, and calling `inspect` on it could
      # itself raise — inside the very path that exists to stop a raise.
      def warn_unusable_subject_label_once(label)
        return unless new_subject_label_warning?(:unusable, label.class)

        Rails.logger&.warn(
          "[CurrentScope] config.subject_label is a #{label.class} — it can't name a method and " \
          "can't be called, so every subject is falling back to the default label. Set it to a " \
          "Symbol (e.g. :email), a Proc taking the subject, or nil."
        )
      end

      def warn_subject_label_raised_once(label, error)
        return unless new_subject_label_warning?(:raised, label)

        Rails.logger&.warn(
          "[CurrentScope] config.subject_label raised #{safe_class(error)}: #{safe_message(error)} " \
          "— that subject fell back to the default label rather than erroring the page. A " \
          "subject_label must be total: it runs for every subject, including ones with nil or " \
          "blank attributes."
        )
      end

      # The configured value could not even be classified — see the rescue in
      # configured_subject_label. Keyed by the error's class, and says nothing
      # about the label itself, because reading the label is what failed.
      def warn_subject_label_broken_once(error)
        return unless new_subject_label_warning?(:broken, safe_class(error))

        Rails.logger&.warn(
          "[CurrentScope] config.subject_label could not be read — #{safe_class(error)}: " \
          "#{safe_message(error)}. Every subject is falling back to the default label. Set it to " \
          "a Symbol (e.g. :email), a Proc taking the subject, or nil."
        )
      end

      private

      # A host exception's message is arbitrary text produced by arbitrary code:
      # it may carry newlines that split one warning across several log records,
      # run to any length, or raise from #message itself. All three would land
      # in the rescue this runs inside — reporting the failure must not become
      # the failure.
      def safe_message(error)
        error.message.to_s.gsub(/\s+/, " ").strip.truncate(200)
      rescue StandardError
        "(message unavailable)"
      end

      # Same reason as safe_message, one step earlier: `#class` is interpolated
      # before safe_message is even called, and an exception raised by a host
      # Proc can override it. The method-level rescue in configured_subject_label
      # does stop that reaching the page — but at the cost of the accurate
      # warning, replaced by a misattributed one about the secondary failure.
      # The diagnostic is the whole point of warning at all, so protect it.
      def safe_class(error)
        error.class.name.presence || "an exception"
      rescue StandardError
        "an exception"
      end

      # Set is a core built-in on this gem's Ruby floor (>= 3.2, no require
      # needed — the codebase already uses bare Set elsewhere), so nothing here
      # can raise inside the rescue this runs under.
      def new_subject_label_warning?(reason, label)
        @subject_label_warnings ||= Set.new
        !!@subject_label_warnings.add?([ reason, label ])
      end
    end
  end
end
