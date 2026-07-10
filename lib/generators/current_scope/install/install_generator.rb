module CurrentScope
  module Generators
    class InstallGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_initializer
        template "initializer.rb", "config/initializers/current_scope.rb"
      end

      def mount_engine
        route 'mount CurrentScope::Engine => "/current_scope"'
      end

      def show_next_steps
        say <<~NEXT

          CurrentScope installed. Next steps:

            1. bin/rails current_scope:install:migrations && bin/rails db:migrate
            2. Include the concerns in ApplicationController (Context first):
                 include CurrentScope::Context
                 include CurrentScope::Guard
            3. Seed the baseline roles and give yourself full access, e.g. in db/seeds.rb:
                 CurrentScope.seed_defaults!
                 CurrentScope::RoleAssignment.create!(
                   subject: User.first, role: CurrentScope::Role.find_by!(name: "Owner"))
            4. Manage roles at /current_scope (full-access subjects only).

        NEXT
      end
    end
  end
end
