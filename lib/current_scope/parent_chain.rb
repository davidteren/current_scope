module CurrentScope
  # The ONE answer to "what are this record's declared ancestors?" (#108).
  #
  # A model opts in with `current_scope_parent :project`. The resolver, failing a
  # direct scoped-grant match, walks that chain and matches grants against the
  # ancestors instead. Flat stays the default: a model that declares nothing gets
  # an empty chain and a byte-identical decision.
  #
  # WHY A MACRO, when every other host hook (current_scope_record,
  # current_scope_model, current_scope_initiator, current_scope_sod_bypassed?) is
  # a plain method: those answer a per-INSTANCE question, so returning a value is
  # enough. This one must also produce a QUERYABLE key — Resolver#scope_for builds
  # `where(<foreign_key> => granted_ancestor_ids)`, and a method handing back a
  # parent instance cannot yield a foreign key without loading every candidate
  # row. Naming an association gives both derivations (the walk and the query)
  # from one declaration, so the gate and the list cannot drift. The departure is
  # deliberate and documented in the README rather than left to surprise a reader.
  module ParentChain
    # A private ceiling, not a config knob: nobody can pick a default for a knob
    # before a host declares a chain deep enough to need it. Raise it when one
    # asks. Exceeding it raises — a walk that silently stopped would answer
    # "no grant" for a subject who holds one, which is a denial nobody can
    # diagnose.
    MAX_PARENT_DEPTH = 5

    # Installed on ActiveRecord::Base via ActiveSupport.on_load — the standard
    # engine idiom for an acts_as_*-style declaration. Deliberately NOT hung off
    # CurrentScope::Scopeable, whose contract is "BROWSE-ONLY — it does NOT gate
    # access" (scopeable.rb:3) and whose `included` hook would also register the
    # model in the scoped-role picker as a side effect of declaring a parent.
    module Declaration
      def current_scope_parent(association_name)
        reflection = reflect_on_association(association_name)

        if reflection.nil?
          raise ConfigurationError,
                "#{name}.current_scope_parent(#{association_name.inspect}) names an " \
                "association that does not exist. Declare `belongs_to " \
                "#{association_name.inspect}` first, or name the association that " \
                "reaches the record scoped grants are held on."
        end

        unless reflection.belongs_to?
          raise ConfigurationError,
                "#{name}.current_scope_parent(#{association_name.inspect}) must name a " \
                "belongs_to association — #{association_name.inspect} is a " \
                "#{reflection.macro}. A scoped grant is held on ONE parent record, so " \
                "the chain walks upward one owner at a time."
        end

        if reflection.polymorphic?
          raise ConfigurationError,
                "#{name}.current_scope_parent(#{association_name.inspect}) names a " \
                "polymorphic belongs_to, which is not supported: the parent's class is " \
                "not knowable without loading every candidate row, so scope_for could " \
                "not build its query. Declare a concrete belongs_to instead."
        end

        self.current_scope_parent_association = association_name.to_sym
      end

      def current_scope_parent_declared?
        !current_scope_parent_association.nil?
      end
    end

    class << self
      # The ancestors a scoped grant may be matched against, nearest parent
      # first, root last. Empty for an unopted model, a class, or an unsaved
      # record — all three are "nothing to walk", not an error.
      def ancestors_for(record)
        return [] unless record.respond_to?(:new_record?) && record.persisted?

        unless declared?(record.class)
          reject_method_form!(record)
          return []
        end

        walk(record)
      end

      # Whether this class (or an STI ancestor it inherits from) opted in.
      def declared?(klass)
        klass.respond_to?(:current_scope_parent_declared?) && klass.current_scope_parent_declared?
      end

      # The declared association reflection, or nil. scope_for reads this for the
      # foreign key; it must never re-derive the name itself.
      def reflection_for(klass)
        return nil unless declared?(klass)

        klass.reflect_on_association(klass.current_scope_parent_association)
      end

      private

      def walk(record)
        ancestors = []
        seen = [ identity(record) ]
        current = record

        while (reflection = reflection_for(current.class))
          parent = current.public_send(reflection.name)
          break if parent.nil? # optional: belongs_to, or an unset column — normal data

          key = identity(parent)
          raise ConfigurationError, cycle_message(seen, key) if seen.include?(key)

          ancestors << parent
          raise ConfigurationError, depth_message(seen, key) if ancestors.size > MAX_PARENT_DEPTH

          seen << key
          current = parent
        end

        ancestors
      end

      # Grants store the polymorphic base_class, so identity must too — otherwise
      # an STI parent and its base would read as different records and a cycle
      # through them would not be caught.
      def identity(record)
        [ record.class.base_class.name, record.id ]
      end

      def cycle_message(seen, repeat)
        "current_scope_parent forms a cycle: #{chain_text(seen + [ repeat ])}. " \
        "A chain must terminate at a record with no parent. Remove one of the " \
        "current_scope_parent declarations in that loop."
      end

      def depth_message(seen, last)
        "current_scope_parent chain is deeper than #{MAX_PARENT_DEPTH}: " \
        "#{chain_text(seen + [ last ])}. Shorten the chain, or grant on a record " \
        "nearer the one being acted on."
      end

      def chain_text(keys)
        keys.map { |type, id| "#{type}##{id}" }.join(" -> ")
      end

      # A host that writes `def current_scope_parent = project` has written a
      # method that nothing calls: the declaration is a class macro. Every other
      # current_scope_* hook IS an instance method, so this is the mistake the
      # name invites, and silence would be indistinguishable from "flat by
      # design". Raised on the first decision that would have walked, which is
      # where sod_decision raises for a missing current_scope_initiator too.
      def reject_method_form!(record)
        return unless record.respond_to?(:current_scope_parent)

        raise ConfigurationError,
              "#{record.class.name} defines an INSTANCE method " \
              "`current_scope_parent`, but the declaration is a class-level macro " \
              "and nothing reads that method. Replace it with " \
              "`current_scope_parent :the_association` in the class body."
      end
    end
  end
end
