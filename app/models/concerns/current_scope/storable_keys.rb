module CurrentScope
  # One definition of the #151 key policy, shared by both assignment models.
  #
  # Since the ids are string columns, an integer key and a UUID both store whole.
  # What remains unstorable is a key that is not ONE value: a composite key is an
  # array, and a model with no primary key names no record. A grant on either
  # would identify the wrong row or none, so it is refused.
  module StorableKeys
    extend ActiveSupport::Concern

    class_methods do
      # `sides` are the polymorphic association names ("subject", "resource").
      def validates_storable_polymorphic_keys(*sides)
        validate { current_scope_check_storable_keys(sides) }
      end

      # Rails reverse-resolves the stored token via polymorphic_class_for.
      # A custom token is not a constant; route it through the engine registry.
      # Do not fall through to Rails constantize when the registry is empty:
      # a token that equals another class name would bind the wrong model.
      def polymorphic_class_for(name)
        # inert_on_error: a poisoned registry becomes the NameError every console
        # reader already rescues, instead of a ConfigurationError none of them do.
        # NameError is not a downgrade of the diagnosis, because the cause travels
        # in the message: Rails calls this hook from association loads AND from the
        # belongs_to presence validator, so a write under a poisoned registry still
        # fails closed, and it says WHY rather than claiming the token is unmapped.
        CurrentScope.polymorphic_class(name, inert_on_error: true) ||
          raise(NameError, unmapped_token_message(name))
      end

      def unmapped_token_message(name)
        cause = CurrentScope::Current.polymorphic_registry_error
        return "unmapped polymorphic token #{name.inspect}" if cause.blank?

        "unmapped polymorphic token #{name.inspect}: #{cause}"
      end
    end

    # Associations cast their stored id through the target model's key type.
    # For a legacy collapsed row that can turn a UUID-shaped string into integer
    # record 7. Every engine path that labels or audits an existing grant uses
    # this checked reader so an inert grant never names an unrelated live record.
    def current_scope_resolved_record(side)
      klass = CurrentScope.polymorphic_class(public_send("#{side}_type"), inert_on_error: true)
      return if klass.nil?

      id = public_send("#{side}_id")
      return unless CurrentScope.canonical_key?(klass, id)

      association = association(side.to_sym)
      if association.loaded?
        target = association.target
        return target if target && target.class.base_class == klass.base_class
        return if target.nil?
      end

      record = klass.find_by(klass.primary_key => id)
      # Cache the resolved record onto the association so a second resolve of the
      # same side on this row is free — the members view resolves each holder
      # twice (its label and its Remove-button GID). The registry swap replaced
      # the association reader (which cached) with find_by; this restores that.
      # Association#target= sets @target and marks the association loaded.
      association.target = record if record
      record
    rescue ActiveRecord::RecordNotFound, NameError
      nil
    end

    private

    def current_scope_check_storable_keys(sides)
      # db:setup/reset/prepare must boot before a schema exists, but they later
      # run host seeds in that same process. Re-check at the actual write so a
      # schema-loaded MySQL database cannot create grants before its collation is
      # repaired. Database-task exemptions are only for bootstrapping tooling.
      CurrentScope::SchemaGuard.check!(allow_database_task: false)

      sides.each do |side|
        # LENGTH FIRST, and it ends this side. An id too long for the column is
        # also, necessarily, not a canonical key for its model — checking both
        # would hand the reader two errors for one value, the second one
        # explaining a cast when the real problem is the width.
        next if too_long?(side)

        # The stored TYPE column, not the association: on an already-collapsed row
        # the association resolves to nothing, and reading it would skip exactly
        # the rows this guard exists for. Resolved through this model, which is
        # what wrote the token, so an overridden polymorphic_name still matches.
        klass = CurrentScope.polymorphic_class(public_send("#{side}_type"))
        next if klass.nil?

        # A write fails CLOSED either way, but the two causes get different
        # messages: claiming a model has a composite key when the truth is "its
        # table is missing" sends the reader hunting the wrong problem. Only
        # ActiveRecord errors are converted — a NoMethodError here is a bug in
        # this gem and must surface as one, not as a validation message.
        begin
          unless CurrentScope.storable_key?(klass)
            errors.add(:base, CurrentScope.unstorable_key_error(klass, role: side))
            next
          end

          next if CurrentScope.canonical_key?(klass, public_send("#{side}_id"))

          # The column takes any string, so a value that is not a legal key for
          # this model stores happily — and the resolver then casts it back into
          # that model's key type, where "7f00aaaa-…" becomes 7 and the grant
          # reaches record 7. The resolver drops such ids too; refusing the WRITE
          # is what stops them existing at all.
          errors.add(:base,
            "#{public_send("#{side}_id").inspect} is not a valid #{klass.name} primary key " \
            "(#{klass.name}.#{klass.primary_key} is #{klass.type_for_attribute(klass.primary_key).type}). " \
            "Stored as-is it would be cast back to a DIFFERENT record's id, so the grant would " \
            "open a record it does not name (#151).")
        rescue ActiveRecord::ActiveRecordError => e
          errors.add(:base,
            "#{klass.name}'s primary key could not be read (#{e.class}: #{e.message}), so " \
            "CurrentScope cannot prove this #{side} names one record. Refusing the grant " \
            "rather than storing something unverified.")
        end
      end
    end

    # Length is a correctness guard, not cosmetics: a truncated key is a key that
    # names the wrong record (#151). Returns whether it failed, so the caller can
    # stop looking at a side whose value is already disqualified.
    def too_long?(side)
      value = public_send("#{side}_id")
      return false unless CurrentScope.key_too_long?(value)

      errors.add(:base,
        "#{side} id is #{value.to_s.length} characters; CurrentScope stores it in a " \
        "#{CurrentScope::KEY_LIMIT}-character column, and a truncated key would name the " \
        "wrong record. Use a shorter primary key.")
      true
    end
  end
end
