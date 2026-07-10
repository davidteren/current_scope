module CurrentScope
  class Engine < ::Rails::Engine
    isolate_namespace CurrentScope

    # Routes (and therefore the derived permission catalog) can change on
    # every code reload in development.
    config.to_prepare do
      CurrentScope.reset_catalog!
    end
  end
end
