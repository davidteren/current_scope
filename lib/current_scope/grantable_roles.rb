module CurrentScope
  # Opt-in: which ROLES may be granted on a resource type (#183).
  #
  # Included by CurrentScope::Scopeable, and includable on its own by a type
  # that wants the rule without appearing in the console's picker — Scopeable is
  # browse-only by design, and a type that should never be browsable may still
  # want to say which roles belong on it.
  #
  #   class Workstream < ApplicationRecord
  #     include CurrentScope::Scopeable
  #     self.current_scope_grantable_roles = %w[Lead]
  #   end
  #
  # Absent a declaration this changes nothing: any role stays grantable on any
  # type, which is what every existing host has.
  #
  # WHY IT EXISTS. A role's permission bundle is written for one shape of
  # record. With parent-chain resolution a grant held on a CONTAINER resolves
  # for every record inside it, so pairing a per-record role with a container
  # type hands the subject that per-record surface across the whole container —
  # an assignment nobody designed, made by one wrong pick in a dropdown.
  #
  # Declared on the RESOURCE rather than on the role, because the resource is
  # already where a host declares how it participates (current_scope_parent, the
  # searchable scope, Scopeable), it needs no migration and no admin screen, and
  # it is versioned in the code review that introduces the pairing.
  module GrantableRoles
    extend ActiveSupport::Concern

    class_methods do
      # A SETTER, not an overloaded reader (#183 review). A combined
      # `current_scope_grantable_roles(*names)` cannot tell
      # `current_scope_grantable_roles(*computed)` with an empty `computed` from
      # a read, so a host computing the list would have silently declared
      # nothing and left the type open to every role. An assignment is
      # unambiguous, matches `self.table_name =`, and makes an empty list a real
      # declaration.
      #
      # An empty list is a LOCKDOWN: no role may be granted on this type. `nil`
      # is the opposite and means NO declaration (inherit, else accept
      # everything), so a host reading its list from config still gets the
      # documented default when the key is missing — the two values read the
      # same way as they are written (#183 review).
      def current_scope_grantable_roles=(names)
        @current_scope_grantable_roles =
          if names.nil?
            nil
          else
            # Role RECORDS are accepted too: to_s on one yields an inspect
            # string that can never match, which would be a silent lockdown —
            # the failure this setter exists to prevent (#183 review).
            # Blanks are dropped rather than stored: `%w[Lead] + [ENV["EXTRA"]]`
            # with the variable unset would otherwise declare "", which matches
            # no role and silently locks the type down — the same failure the
            # setter exists to prevent (#183 review).
            Array(names).flatten
                        .map { |name| name.respond_to?(:name) ? name.name : name.to_s }
                        .reject(&:blank?).freeze
          end
      end

      def current_scope_grantable_roles
        declared = @current_scope_grantable_roles if defined?(@current_scope_grantable_roles)
        return declared unless declared.nil?

        # A subclass inherits the parent's declaration until it states its own:
        # a grant on Report and on UrgentReport answer the same question about
        # the same table.
        return superclass.current_scope_grantable_roles if superclass.respond_to?(:current_scope_grantable_roles)

        nil
      end

      # THE rule, in one place, so the gate and the console cannot drift. nil
      # means the type never declared anything and accepts everything; an empty
      # declaration accepts nothing.
      #
      # Matched by NAME, and that is the trade a declaration written in code
      # makes: role ids are per-database and cannot be named in a model file.
      # Renaming a role therefore stops the declarations that name it from
      # matching, and a new role that reuses the name inherits its acceptance.
      # Adding a declaration rewrites no existing grant, but the check runs on
      # every write rather than on create alone, so a pre-existing row that the
      # declaration refuses fails the next time host code saves it — an update
      # must meet the same rule as the create did.
      def current_scope_grants_role?(role)
        allowed = current_scope_grantable_roles
        return true if allowed.nil?

        role.present? && allowed.include?(role.name)
      end
    end
  end
end
