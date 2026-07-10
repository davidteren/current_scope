module CurrentScope
  class Configuration
    # Host controller method that returns the authenticated subject.
    attr_accessor :user_method

    # Action names subject to the separation-of-duties veto: whoever initiated
    # a record can never perform these actions on it. Not editable in the UI
    # by design — SoD is a structural guarantee, not a preference.
    attr_accessor :sod_actions

    # Method the host declares on records that need SoD, returning the subject
    # who initiated the record.
    attr_accessor :initiator_method

    # Regexps matched against controller paths to keep infrastructure
    # controllers out of the permission grid.
    attr_accessor :excluded_controllers

    # Class the management UI's controllers inherit from, so they pick up the
    # host's authentication and layout.
    attr_accessor :parent_controller

    # Host class acting as the subject, used by the management UI to list
    # assignable subjects.
    attr_accessor :subject_class

    def initialize
      @user_method = :current_user
      @sod_actions = %w[approve]
      @initiator_method = :current_scope_initiator
      @excluded_controllers = [
        %r{\Arails/}, %r{\Aactive_storage/}, %r{\Aaction_mailbox/},
        %r{\Aturbo/}, %r{\Acurrent_scope/}
      ]
      @parent_controller = "::ApplicationController"
      @subject_class = "User"
    end
  end
end
