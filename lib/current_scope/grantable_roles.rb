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
      # A SETTER, not an overloaded reader (#183). A combined
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
      # same way as they are written (#183).
      def current_scope_grantable_roles=(names)
        @current_scope_grantable_roles =
          if names.nil?
            nil
          else
            # Role RECORDS and blanks both: to_s on a Role yields an inspect
            # string that matches nothing, and `%w[Lead] + [ENV["EXTRA"]]` with
            # the variable unset would declare "" — each a silent narrowing. A
            # list that is ALL blanks lands on [], the lockdown, which is the
            # fail-closed answer; a host that means "no declaration" assigns nil.
            Array(names).flatten
                        .map { |name| name.respond_to?(:name) ? name.name : name.to_s }
                        .reject(&:blank?).freeze
          end
      end

      def current_scope_grantable_roles
        # No `defined?` guard: never declared and explicitly nil are the SAME
        # state by design (the guide documents nil as "no declaration"), and a
        # guard here would imply a distinction this predicate does not make.
        declared = @current_scope_grantable_roles
        return declared unless declared.nil?

        # A subclass inherits the parent's declaration until it states its own:
        # a grant on Report and on UrgentReport answer the same question about
        # the same table.
        return superclass.current_scope_grantable_roles if superclass.respond_to?(:current_scope_grantable_roles)

        nil
      end

      # True when this class OR one of its loaded descendants declares its
      # grantable roles, which is the only case where filtering by role can drop
      # a record. The `_anywhere?` says so, matching
      # current_scope_locked_down_everywhere?: a receiver-only reading of the
      # bare name would be wrong. It lives here rather than in the console so a
      # caller asking "can a declaration govern this type?" finds it beside the
      # other predicates (#183).
      #
      # LOADED descendants on purpose, where its sibling asks the rows instead.
      # The two are wrong in different currencies: this one only widens or
      # narrows a fetch, so missing an unloaded subclass costs a search that
      # reads 50 rows instead of 500, while the lockdown answer would state
      # something false to the operator, which is worth a query. The guide names
      # the development-console gap this leaves.
      def current_scope_declares_roles_anywhere?
        return true unless current_scope_grantable_roles.nil?
        return false unless respond_to?(:descendants)

        descendants.any? { |sub| !sub.try(:current_scope_grantable_roles).nil? }
      end

      # Locked all the way DOWN: this type declares an empty list and nothing
      # over its table states one of its own. A locked base binds only the
      # records that INHERIT it, so over a declaring subclass's rows "no role
      # will help" is false — the console asks this before it says so (#183).
      def current_scope_locked_down_everywhere?
        return false unless current_scope_locked_down?
        return true unless current_scope_inheritable_table?

        !current_scope_rows_outside?(current_scope_locked_class_names)
      rescue ActiveRecord::ActiveRecordError
        false # no database to ask; do not claim a lockdown we cannot check
      end


      # True when rows of this table can load as some other class.
      def current_scope_inheritable_table?
        return false unless respond_to?(:has_attribute?) && respond_to?(:inheritance_column)

        has_attribute?(inheritance_column)
      end

      # An empty declaration is a LOCKDOWN: no role may be granted on this type.
      # Written here rather than spelled out at each call site, so what "empty
      # declaration" means stays where the other two predicates live (#183
      # review).
      def current_scope_locked_down?
        current_scope_grantable_roles&.empty? || false
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
      #
      # A nil role RAISES rather than answering. Answering false would be the
      # fail-closed reading, but on the same object `current_scope_grantable_
      # roles` returning nil means "accepts every role", so one value would mean
      # opposite things three lines apart — and a host writing the obvious
      # `next unless klass.current_scope_grants_role?(role)` over a role nobody
      # has chosen yet would silently refuse every type. That misreading already
      # broke the documented deep link once inside this feature. A caller that
      # means "nothing chosen yet, do not filter" says so itself; every caller
      # in this engine returns early on a nil role before it asks.
      def current_scope_grants_role?(role)
        raise ArgumentError, "current_scope_grants_role? needs a role; nil is not one" if role.nil?

        allowed = current_scope_grantable_roles
        return true if allowed.nil?

        # A NAME is as good as a Role here, the way the setter takes either:
        # the guide writes declarations as strings, so a host asking about one
        # by name is the first thing to try (#183).
        name = role.respond_to?(:name) ? role.name : role.to_s
        name.present? && allowed.include?(name)
      end

      private

      # The stored names of every LOADED class here that accepts no role. Each
      # through Rails' own sti_name, never the constant name: a stored type is
      # not always one — `store_full_sti_class = false` shortens it and
      # `sti_name` can be overridden — which is the hazard PolymorphicRegistry
      # documents for its own tokens.
      def current_scope_locked_class_names
        ([ self ] + descendants)
          # empty?, not blank?: nil is "no declaration, accepts everything" and
          # [] is "accepts nothing" — the opposite ends of this module's
          # contract. The reader walks to the superclass, so a descendant of a
          # locked class reads [] rather than nil today; saying empty? here
          # keeps that a fact about the data rather than a coincidence.
          .select { |klass| klass.try(:current_scope_grantable_roles)&.empty? }
          .map { |klass| klass.try(:sti_name) }
          .compact
      end

      # Is there a row here whose class is NOT one of those? An EXISTS, so it
      # stops at the first one rather than aggregating the table: a DISTINCT
      # would consume every matching row before any LIMIT applied, on a column
      # Rails does not index, once per render of a locked type.
      #
      # A row naming a class this process has not loaded is not in the list, so
      # it answers "yes, something else is here" and the lockdown is not
      # claimed. That is the safe direction: `descendants` alone would read an
      # unloaded declaring subclass as "nothing declares" and state a lockdown
      # that is false.
      def current_scope_rows_outside?(names)
        where.not(inheritance_column => names + [ nil ]).exists?
      end
    end
  end
end
