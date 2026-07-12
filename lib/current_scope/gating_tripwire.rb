module CurrentScope
  # A4: an opt-in dev/test tripwire that catches an action which completed
  # WITHOUT being gated by Guard's current_scope_check!. Include it on a base
  # controller you want verified — INCLUDING one that never includes Guard (an
  # API base, a hand-rolled ActionController::Base), which is exactly the
  # ungated case Guard's own after_action could never see.
  #
  #   class ApiController < ActionController::Base
  #     include CurrentScope::GatingTripwire
  #     current_scope_skip_tripwire! only: :health   # mark genuinely-public actions
  #   end
  #
  # It owns its skip API on purpose: it can NOT reuse
  # `skip_before_action :current_scope_check!`, because on a controller that
  # never included Guard that callback is undefined and skip_before_action
  # raises ArgumentError at class load — self-defeating on the very controllers
  # the tripwire targets. `current_scope_skip_tripwire!` skips the tripwire's own
  # after_action instead.
  #
  # Known blind spot: an after_action does not run when a before_action halts the
  # chain (render/redirect) — so an action that renders straight from a
  # before_action escapes the tripwire. It is a strong dev/test aid, not total
  # coverage (Grape/Rack endpoints are out of reach for the same reason).
  module GatingTripwire
    extend ActiveSupport::Concern

    included do
      after_action :current_scope_verify_gated!
    end

    class_methods do
      # The tripwire's OWN exempt marker. Accepts the usual callback filters
      # (only:/except:) and simply skips the tripwire after_action for them.
      def current_scope_skip_tripwire!(**options)
        skip_after_action :current_scope_verify_gated!, **options
      end
    end

    private

    def current_scope_verify_gated!
      # Guard sets @current_scope_checked when current_scope_check! runs. A
      # controller carrying only this mixin (no Guard) never sets it.
      return if instance_variable_defined?(:@current_scope_checked) && @current_scope_checked

      raise CurrentScope::ConfigurationError,
            "\"#{controller_path}##{action_name}\" completed without running current_scope_check! — " \
            "this controller is not gated by CurrentScope::Guard. Include CurrentScope::Guard on its " \
            "base controller, or mark this action public with " \
            "`current_scope_skip_tripwire! only: :#{action_name}`."
    end
  end
end
