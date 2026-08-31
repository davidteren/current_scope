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
    # refused_link: a deep-linked record the chosen role may not be granted on.
    # It belongs to this step because its refusal is often WHY no type is on
    # screen, and the sentence naming it renders above the dropdown.
    def initialize(all_types:, offered:, resolved:, role:, anchor: nil, refused_link: nil)
      @all_types = all_types
      @offered = offered
      @resolved = resolved
      @role = role
      @anchor = anchor
      @refused_link = refused_link
    end

    attr_reader :refused_link

    # A type reached by deep link need not be registered, so it cannot be
    # resolved from its NAME on the next request — only from a record. The
    # cascade carries the gid that anchors it (#183 review).
    def anchor_gid
      @anchor&.to_gid&.to_s unless @offered.include?(@resolved)
    end

    # :none_accept        — types are registered, none accepts the chosen role
    # :none_accept_locked — every registered type declares an empty list, so no
    #                       role will ever list one
    # :unregistered       — nothing has opted into the picker yet
    # :choose             — show the dropdown
    #
    # A resolved type wins over both: it is a target the operator can still
    # grant on, and printing "no type accepts this role" over it would be both
    # a dead end and untrue.
    def state
      return :choose if @resolved || @offered.any?
      return :unregistered unless @all_types.any? && @role
      # Every registered type is a lockdown: no role will ever list one, so
      # "pick a different role" is a promise none of them can keep.
      return :none_accept_locked if locked_count == @all_types.size

      :none_accept
    end

    def withheld_types
      @all_types - @offered
    end

    def withheld_count
      withheld_types.size
    end

    # A type that declares an EMPTY list is a lockdown: withheld for every role,
    # so "pick a different role to see it" is a promise no role can keep
    # (#183 review).
    #
    # Counted among the WITHHELD types, not all of them: a locked STI base is
    # kept on offer anyway (its subclasses may declare their own roles), and
    # counting it here would describe types that are on the list.
    def locked_count
      withheld_types.count { |klass| klass.try(:current_scope_locked_down?) }
    end

    def all_withheld_locked?
      withheld? && locked_count == withheld_count
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
