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

    # How many distinct row kinds a lockdown answer will look at. A table with
    # more than this is not judged on a page render (#183).
    TYPE_SCAN_CAP = 25

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

      # True when this class or a LOADED descendant declares its grantable roles,
      # which is the only case where filtering by role can drop a record. Here
      # rather than in the console, so a caller asking "can a declaration govern
      # this type?" finds it beside the other predicates (#183).
      #
      # ponytail: descendants sees what is LOADED. Rails eager-loads in
      # production; under lazy loading a declaring subclass can be missed, and
      # the caller that reads this decides how wide to look.
      def current_scope_declares_roles?
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

        classes = current_scope_classes_in_table
        # Too many kinds of row to judge on a page render: say nothing rather
        # than scan the table for a message. The rest of the picker bounds its
        # reads the same way.
        return false if classes.size > TYPE_SCAN_CAP

        classes.all? { |klass| klass && klass.try(:current_scope_grantable_roles).blank? }
      rescue ActiveRecord::ActiveRecordError
        false # no database to ask; do not claim a lockdown we cannot check
      end

      # The classes the ROWS name, not the ones this process happens to have
      # loaded. `descendants` sees only loaded classes, so a subclass nothing
      # has referenced yet would read as "no subclass declares" and the console
      # would state a lockdown that is false — hiding the search that reaches
      # those very records.
      #
      # Through Rails' OWN sti_class_for, never safe_constantize: a stored type
      # is not always a constant name. `store_full_sti_class = false` shortens
      # it, `sti_name` can be overridden, and a bare "Invoice" under
      # Billing::Document must not resolve to an unrelated top-level ::Invoice —
      # the same hazard PolymorphicRegistry documents for its own tokens. An
      # unresolvable one answers nil, which fails toward NOT claiming.
      def current_scope_classes_in_table
        where.not(inheritance_column => nil)
             .distinct
             .limit(TYPE_SCAN_CAP + 1)
             .pluck(inheritance_column)
             .map { |stored| current_scope_sti_class(stored) }
      end

      def current_scope_sti_class(stored)
        sti_class_for(stored.to_s)
      rescue ActiveRecord::SubclassNotFound, NameError
        nil
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
      # A nil role answers FALSE here: nothing can be granted for a role that is
      # not there, and for a predicate that guards a write the missing-value
      # answer has to be the closed one. A caller that means "no role chosen
      # yet, so do not filter" (the console's picker) has to say that itself —
      # asking this method would read the absence as a refusal, which is the
      # reading that broke the documented deep link during this feature's own
      # review (#183). Every caller in this engine guards for that reason:
      # the picker in `filter_allows?`, the model gate and the report task each
      # return early on a nil role before they ask.
      def current_scope_grants_role?(role)
        return false if role.nil?

        allowed = current_scope_grantable_roles
        return true if allowed.nil?

        # A NAME is as good as a Role here, the way the setter takes either:
        # the guide writes declarations as strings, so a host asking about one
        # by name is the first thing to try (#183).
        name = role.respond_to?(:name) ? role.name : role.to_s
        name.present? && allowed.include?(name)
      end
    end
  end
end
