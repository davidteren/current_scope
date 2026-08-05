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
    end

    private

    def current_scope_check_storable_keys(sides)
      sides.each do |side|
        # The stored TYPE column, not the association: on an already-collapsed row
        # the association resolves to nothing, and reading it would skip exactly
        # the rows this guard exists for. Resolved through this model, which is
        # what wrote the token, so an overridden polymorphic_name still matches.
        klass = CurrentScope.polymorphic_class(public_send("#{side}_type"), owner: self.class)
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
      check_key_lengths(sides)
    end

    # Length is a correctness guard, not cosmetics: a truncated key is a key that
    # names the wrong record (#151).
    def check_key_lengths(sides)
      sides.each do |side|
        value = public_send("#{side}_id")
        next unless CurrentScope.key_too_long?(value)

        errors.add(:base,
          "#{side} id is #{value.to_s.length} characters; CurrentScope stores it in a " \
          "#{CurrentScope::KEY_LIMIT}-character column, and a truncated key would name the " \
          "wrong record. Use a shorter primary key.")
      end
    end
  end
end
