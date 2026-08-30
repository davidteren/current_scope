module CurrentScope
  # Opt-in: which ROLES may be granted on a resource type (#183).
  #
  # Included by CurrentScope::Scopeable, and includable on its own by a type
  # that wants the rule without appearing in the console's picker — Scopeable is
  # browse-only by design, and a type that should never be browsable may still
  # want to say which roles belong on it.
  module GrantableRoles
    extend ActiveSupport::Concern

    class_methods do
      #   class Workstream < ApplicationRecord
      #     include CurrentScope::Scopeable
      #     current_scope_grantable_roles "Lead"
      #   end
      #
      # Absent a declaration this changes nothing: any role stays grantable on
      # any type, which is what every existing host has.
      #
      # WHY IT EXISTS. A role's permission bundle is usually written for one
      # shape of record. With parent-chain resolution a grant held on a
      # CONTAINER resolves for every record inside it, so pairing a per-record
      # role with a container type hands the subject that per-record surface
      # across the whole container — an assignment nobody designed, made by one
      # wrong pick in a dropdown. Nothing objected before this.
      #
      # Declared on the RESOURCE rather than on the role, because the resource
      # is already where a host declares how it participates
      # (current_scope_parent, the searchable scope, Scopeable), it needs no
      # migration and no admin screen, and it is versioned in the code review
      # that introduces the pairing.
      # COMPUTING THE LIST: pass the array, do not splat it.
      # `current_scope_grantable_roles(*computed)` with an empty `computed`
      # cannot be told apart from the reader, so it would silently declare
      # nothing. `current_scope_grantable_roles(computed)` is unambiguous, and an
      # empty array declared that way means NO role may be granted on this type.
      def current_scope_grantable_roles(*names)
        @current_scope_grantable_roles = names.flatten.map(&:to_s).freeze if names.any?
        return @current_scope_grantable_roles if defined?(@current_scope_grantable_roles)

        # A subclass inherits the parent's declaration until it states its own:
        # a grant on Report and on UrgentReport answer the same question about
        # the same table.
        return superclass.current_scope_grantable_roles if superclass.respond_to?(:current_scope_grantable_roles)

        nil
      end

      # THE rule, in one place, so the gate and the console cannot drift (#183
      # review). nil means the type never declared anything and accepts
      # everything; an empty declaration is a lockdown and accepts nothing.
      #
      # Matched by NAME, and that is the trade a declaration written in code
      # makes: role ids are per-database and cannot be named in a model file.
      # Renaming a role therefore stops the declarations that name it from
      # matching, and a new role that reuses the name inherits its acceptance.
      # The check runs on write, so existing grants are unaffected either way.
      def current_scope_grants_role?(role)
        allowed = current_scope_grantable_roles
        return true if allowed.nil?

        role.present? && allowed.include?(role.name)
      end
    end
  end
end
