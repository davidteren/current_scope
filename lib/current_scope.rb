require "current_scope/version"
require "current_scope/configuration"
require "current_scope/permission_catalog"
require "current_scope/resolver"
require "current_scope/permissions"
require "current_scope/context"
require "current_scope/guard"
require "current_scope/engine"

module CurrentScope
  # Raised when the resolver denies an action gated by Guard (or when the
  # management UI is accessed without a full-access role).
  class AccessDenied < StandardError; end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end

    def resolver
      @resolver ||= Resolver.new
    end

    def catalog
      @catalog ||= PermissionCatalog.new
    end

    def reset_catalog!
      @catalog = nil
    end

    # The single entry point behind every allowed_to? call.
    # `action` is either a full permission key ("admin/reports#approve") or a
    # bare action name resolved against `record`'s route key, falling back to
    # `controller_path`.
    def allowed?(action, subject:, record: nil, controller_path: nil)
      resolver.allow?(
        subject: subject,
        permission: permission_key(action, record: record, controller_path: controller_path),
        record: record
      )
    end

    def permission_key(action, record: nil, controller_path: nil)
      action = action.to_s
      return action if action.include?("#")
      return "#{record.model_name.route_key}##{action}" if record.respond_to?(:model_name)
      return "#{controller_path}##{action}" if controller_path

      raise ArgumentError,
            "cannot derive a permission key for #{action.inspect} — pass a record, " \
            "a full \"controller#action\" string, or call from a controller/view"
    end

    # Creates the two baseline roles every install needs: an Owner with
    # full_access (present and future permissions) and a Member baseline.
    # Call from db/seeds.rb.
    def seed_defaults!
      Role.find_or_create_by!(name: "Owner") { |r| r.full_access = true }
      Role.find_or_create_by!(name: "Member")
    end
  end
end
