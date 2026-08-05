module CurrentScope
  # One definition of the #151 key policy, shared by both assignment models.
  #
  # `subject_id` and `resource_id` are integer columns, so a non-integer primary
  # key is cast on write and distinct records collapse into one identity. The
  # policy has three moving parts that must stay in step — how a stored type token
  # is resolved, what happens when the key cannot be introspected, and the message
  # — so it lives here rather than being written twice. A security rule that is
  # duplicated is a security rule that drifts.
  module IntegerKeys
    extend ActiveSupport::Concern

    class_methods do
      # `sides` are the polymorphic association names ("subject", "resource").
      def validates_integer_polymorphic_keys(*sides)
        validate { current_scope_check_key_types(sides) }
      end
    end

    private

    def current_scope_check_key_types(sides)
      sides.each do |side|
        # The stored TYPE column, not the association: on an already-collapsed row
        # the association resolves to nothing, and reading it would skip exactly
        # the rows this guard exists for. Resolved through this model, which is
        # what wrote the token, so an overridden polymorphic_name still matches.
        klass = CurrentScope.polymorphic_class(public_send("#{side}_type"), owner: self.class)
        next if klass.nil?

        # A write fails CLOSED: if the key cannot be introspected, refuse rather
        # than store a value we cannot prove the column holds.
        safe = begin
          CurrentScope.integer_keyed?(klass)
        rescue StandardError
          false
        end
        next if safe

        errors.add(:base, CurrentScope.non_integer_key_error(klass, role: side))
      end
    end
  end
end
