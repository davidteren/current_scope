module CurrentScope
  module Generators
    class IdentityGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      def copy_resolver
        template "subject_identity.rb", "app/models/current_scope_subject_identity.rb"
      end

      def show_next_steps
        say <<~NEXT

          Subject identity stub written. This is not config.subject_label —
          label is display-only; identity is the portable key.

            1. Fill identify / resolve (and unique? / create_placeholder! if
               the key is split across tables).
            2. In config/initializers/current_scope.rb:
                 config.subject_identity = CurrentScopeSubjectIdentity.new
               Or, for a single column:
                 config.subject_identity = :email
            3. Check uniqueness:
                 bin/rails current_scope:identity:check
            4. Dry-run a grant, then write:
                 bin/rails current_scope:identity:setup IDENTITY=email SUBJECT=you@example.com
                 bin/rails current_scope:identity:setup IDENTITY=email SUBJECT=you@example.com WRITE=1
               PLACEHOLDER=1 creates a marked stand-in outside production only.
               Never invent a production subject.

        NEXT
      end
    end
  end
end
