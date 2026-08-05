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

        # A write fails CLOSED: if the key cannot be read at all, refuse rather
        # than store something that names no record.
        safe = begin
          CurrentScope.storable_key?(klass)
        rescue StandardError
          false
        end
        next if safe

        errors.add(:base, CurrentScope.unstorable_key_error(klass, role: side))
      end
    end
  end
end
