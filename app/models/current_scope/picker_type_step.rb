module CurrentScope
  # The scoped-role picker's TYPE step, in one object — the sibling of
  # PickerRecordStep, and for the same reason (#183 review): the count in the
  # hint, the state the page renders and the options in the dropdown are all
  # derived from one set of inputs, so a change to which types are offered
  # cannot leave the sentence beside the dropdown saying something else.
  class PickerTypeStep
    # all_types  every registered Scopeable type, before the role filter
    # offered    what survived it
    # resolved   the type on screen (may be reached by deep link, and then it
    #            need not be registered at all)
    def initialize(all_types:, offered:, resolved:, role:)
      @all_types = all_types
      @offered = offered
      @resolved = resolved
      @role = role
    end

    # :none_accept  — types are registered, and none accepts the chosen role
    # :unregistered — nothing has opted into the picker yet
    # :choose       — show the dropdown
    #
    # A resolved type wins over both: it is a target the operator can still
    # grant on, and printing "no type accepts this role" over it would be both
    # a dead end and untrue.
    def state
      return :choose if @resolved || @offered.any?
      return :none_accept if @all_types.any? && @role

      :unregistered
    end

    def withheld_count
      @all_types.size - @offered.size
    end

    def withheld?
      withheld_count.positive? && @role.present?
    end

    # A deep-linked type may not itself be Scopeable — keep it selectable.
    def options
      names = @offered.map { |model| [ model.model_name.human, model.name ] }
      return names unless @resolved && names.none? { |(_, name)| name == @resolved.name }

      names.unshift([ @resolved.model_name.human, @resolved.name ])
      names
    end
  end
end
