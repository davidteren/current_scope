require "set"

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
  #
  # DECLARATION ERRORS RAISE. DATA NEVER DOES. That split is load-bearing and was
  # learned the hard way in review: the first cut raised ConfigurationError when a
  # record's chain was too deep or looped, which meant two UPDATEs on a parent_id
  # column — no code change at all — could 500 a live request, escape report
  # mode's "never breaks a request" promise, and print a fix ("remove one of the
  # current_scope_parent declarations") pointing at code that was correct. So:
  # a bad DECLARATION raises at declaration time, where the host can only hit it
  # by writing it; bad or over-deep DATA truncates the walk, denies (fail-closed),
  # and warns once.
  module ParentChain
    # A private ceiling, not a config knob: nobody can pick a default for a knob
    # before a host declares a chain deep enough to need it. Raise it when one
    # asks.
    #
    # Truncating past it is FAIL-CLOSED — fewer ancestors means fewer grants
    # match, so the answer is a denial, never an escalation. It is also the only
    # option that keeps the gate and the list agreeing: Resolver#ancestor_scope_for
    # walks CLASSES, and a legitimate self-referential chain (Project belongs_to
    # :parent, class_name: "Project") never terminates at the class level however
    # shallow the data is. A ceiling that raised on one side and truncated on the
    # other is exactly the divergence this constant exists to prevent.
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
                "the chain walks upward one owner at a time. Declare it on the CHILD " \
                "instead — `current_scope_parent` in #{reflection.klass.name} — so a " \
                "grant held here reaches its #{association_name}."
        end

        if reflection.polymorphic?
          raise ConfigurationError,
                "#{name}.current_scope_parent(#{association_name.inspect}) names a " \
                "polymorphic belongs_to, which is not supported: the parent's class is " \
                "not knowable without loading every candidate row, so scope_for could " \
                "not build its query. Either name a concrete belongs_to if this model " \
                "has one, or keep this model flat and grant on it directly."
        end

        # The walk loads the parent THROUGH the association, so a scope on it is
        # applied; ancestor_scope_for rebuilds the join from the foreign key
        # alone, so the scope never reaches that SQL. The two then disagree in
        # the fail-OPEN direction — the gate denies while the collection-read
        # gate (which is scope_for(...).exists?) allows and the list renders the
        # rows. Refusing the shape is total; supporting it would mean building
        # the arm with joins(reflection.name) so one definition feeds both.
        if reflection.scope
          raise ConfigurationError,
                "#{name}.current_scope_parent(#{association_name.inspect}) names a SCOPED " \
                "belongs_to. The per-record walk would apply that scope and the collection " \
                "query would not, so the gate and the list would disagree about the same " \
                "record. Declare an unscoped belongs_to for the chain."
        end

        # Resolver#scope_for is handed the COLLECTION type a controller names,
        # which for STI is the base class, while the per-record gate reads the
        # declaration off the instance's own class. A chain declared on a
        # subclass would therefore be walked by the gate and invisible to the
        # list — the two disagreeing about the same record. Refusing the shape
        # removes that entire class of drift instead of documenting it.
        if self != base_class
          raise ConfigurationError,
                "#{name}.current_scope_parent(#{association_name.inspect}) is declared on " \
                "an STI subclass. Declare it on #{base_class.name} instead: scoped grants " \
                "store the base class, and the collection query is built from it, so a " \
                "subclass-only chain would open records the list could never show."
        end

        self.current_scope_parent_association = association_name.to_sym
        CurrentScope::ParentChain.register(self)
      end

      def current_scope_parent_declared?
        !current_scope_parent_association.nil?
      end
    end

    class << self
      # Declared classes, by NAME so dev-mode reloading never pins a stale
      # constant (same reason CurrentScope::Scopeable stores strings).
      def register(klass)
        declared_names << klass.name if klass.name
      end

      def declared_names
        @declared_names ||= Set.new
      end

      # Run once at boot (and on reload) rather than on the request path.
      # validate_key! needs reflection.klass, which cannot resolve inside the
      # macro without breaking an ordinary forward reference between two models
      # that name each other — so the check has to happen later. Later must not
      # mean "on the first gated request", because that is a deploy that boots
      # green and 500s on real traffic. (cubic P2, ie-predictability P1)
      #
      # In production this is complete: eager loading has run, so every
      # declaring class is registered. In development it can only see the
      # classes loaded so far, which is the same partial-coverage bargain the
      # permission catalog already makes, and it is stated rather than implied.
      #
      # Iterates a SNAPSHOT, and that is load-bearing rather than defensive:
      # validate_key! resolves reflection.klass, which AUTOLOADS the parent
      # model, and a parent that declares a chain of its own registers itself
      # from its class body — mutating the very Set being iterated. Ruby answers
      # that with "can't add a new key into hash during iteration", i.e. a
      # RuntimeError out of to_prepare on any host whose declared chain points at
      # another declaring model. The dummy's Report -> Project is exactly that
      # shape; it surfaced while pinning #133's boot hook.
      #
      # A class registered mid-pass is therefore not validated in THIS pass. That
      # is the partial-coverage bargain above, unchanged: production has eager
      # loaded before this runs, and development re-validates on the next reload.
      def validate_declarations!
        declared_names.to_a.each do |name|
          klass = name.safe_constantize
          next if klass.nil?

          reflection = klass.reflect_on_association(klass.current_scope_parent_association)
          validate_key!(klass, reflection) if reflection
        end
      end

      # The ancestors a scoped grant may be matched against, nearest parent
      # first, root last. Empty for an unopted model, a class, or an unsaved
      # record — all three are "nothing to walk", not an error.
      def ancestors_for(record)
        return [] unless record.respond_to?(:new_record?) && record.persisted?

        unless declared?(record.class)
          reject_method_form!(record.class)
          return []
        end

        walk(record)
      end

      # Whether this class (or an STI ancestor it inherits from) opted in.
      # `klass < ActiveRecord::Base` rather than a bare respond_to? duck-type:
      # the macro is installed on ActiveRecord::Base, so anything else answering
      # this trio is a coincidence, and honouring it would let a non-AR class
      # steer grant matching. Mirrors the record-less branch's collection_type?
      # guard.
      def declared?(klass)
        klass.is_a?(Class) && klass < ActiveRecord::Base &&
          klass.respond_to?(:current_scope_parent_declared?) &&
          klass.current_scope_parent_declared?
      end

      # The declared association reflection, or nil. scope_for reads this for the
      # foreign key; it must never re-derive the name itself.
      # Resolved from base_class, ALWAYS. The declaration is refused on an STI
      # subclass, but a subclass can still OVERRIDE the association it inherits
      # (a different class_name or foreign key). The per-record gate reads the
      # instance's class and the collection query reads the base, so resolving
      # per-class would let those two walk different associations for the same
      # record — the drift the STI refusal exists to prevent, re-entering by the
      # back door. One declared base reflection feeds both. (cubic P1)
      def reflection_for(klass)
        unless declared?(klass)
          # Both paths funnel through here, so this is where the method-form
          # mistake has to be caught. Checking it only in ancestors_for meant the
          # member gate raised while scope_for silently omitted parent grants —
          # the collection answering :no_grant with no diagnosis. (qodo 3)
          reject_method_form!(klass)
          return nil
        end

        base = klass.base_class
        base.reflect_on_association(base.current_scope_parent_association)
      end

      # Reset between reloads/tests so a truncation warning is not latched by a
      # run that has since been fixed (same reason the gating tripwire resets).
      def reset_warnings!
        @warned = nil
      end

      private

      # Checked HERE, not at declaration time, because it needs reflection.klass
      # and forcing that constant to resolve inside the macro breaks a perfectly
      # ordinary forward reference between two models that name each other. It is
      # still a DECLARATION error, so it raises: no row value can reach it.
      #
      # Rebuilding the join (ancestor_scope_for) assumes the parent is matched on
      # its own primary key. With `primary_key:` set, the child's foreign key
      # holds some other column's values, so joining on the primary key would
      # match a DIFFERENT parent row — a grant on X acting on Y, in the arm that
      # IS the collection-read gate.
      def validate_key!(klass, reflection)
        return if reflection.polymorphic?
        return if reflection.association_primary_key.to_s == reflection.klass.primary_key.to_s

        raise ConfigurationError,
              "#{klass.name}.current_scope_parent(#{reflection.name.inspect}) names a " \
              "belongs_to with a custom association primary key " \
              "(#{reflection.association_primary_key}). The collection query joins on " \
              "#{reflection.klass.name}'s primary key, so it would match the wrong rows. " \
              "Declare a chain that keys on the primary key."
      end

      def warned
        @warned ||= Set.new
      end

      def walk(record)
        ancestors = []
        seen = [ identity(record) ]
        current = record

        while (reflection = reflection_for(current.class))
          parent = load_parent(current, reflection)

          # Normal data, all three: an optional belongs_to with no owner, a
          # parent built in memory but never saved (it can hold no scoped grant),
          # and one destroyed earlier in this request — the association cache
          # would otherwise keep handing back the destroyed object, and matching
          # a grant against it would open access to a record that is gone, which
          # is the one-hop-up form of the AE4 rule.
          break unless walkable?(parent)

          key = identity(parent)
          if seen.include?(key)
            warn_truncated(record, :loop, seen + [ key ])
            break
          end

          ancestors << parent
          seen << key
          current = parent

          if ancestors.size >= MAX_PARENT_DEPTH
            # Only a chain that actually CONTINUES past the ceiling was
            # truncated. A chain of exactly five hops is valid and lost nothing,
            # and warning here would latch [class, :depth] and swallow a later
            # genuine over-depth warning for the same model. (qodo 2 / cubic P3)
            warn_truncated(record, :depth, seen) if next_parent(current)
            break
          end
        end

        ancestors
      end

      # Whether the walk would have continued — used only to decide whether a
      # ceiling stop actually TRUNCATED anything.
      def next_parent(record)
        reflection = reflection_for(record.class)
        return nil unless reflection

        parent = load_parent(record, reflection)
        walkable?(parent) ? parent : nil
      end

      # The three terminal shapes, in ONE place so the walk and the
      # would-it-have-continued check cannot disagree about what counts as a
      # stop. A terminal parent means the walk ended normally and truncated
      # nothing, so it must not warn — and must not latch [class, :depth] and
      # swallow the next real over-depth warning. (cubic P3, second round)
      def walkable?(parent)
        !parent.nil? && !parent.new_record? && !parent.destroyed?
      end

      # F. Read the parent WITHOUT triggering a lazy load. A host running
      # `strict_loading` would otherwise get ActiveRecord::StrictLoadingViolationError
      # from inside the gate — a 500 on ordinary data, which is the failure this
      # module exists to avoid. Uses the already-loaded target when there is one,
      # so `includes(:project)` still pays off. (cubic P2)
      def load_parent(record, reflection)
        # A preloaded target is only trustworthy when the record's own class
        # resolves the SAME association object the base declared. An STI subclass
        # that overrides the inherited association would otherwise make the gate
        # walk a different parent than scope_for queries — resolving the
        # reflection from base_class is not enough on its own, because
        # `record.association(name)` still resolves on the runtime subclass.
        # (cubic P1, second round)
        if record.class.reflect_on_association(reflection.name).equal?(reflection)
          association = record.association(reflection.name)
          return association.target if association.loaded?
        end

        foreign_key = record[reflection.foreign_key]
        return nil if foreign_key.nil?

        reflection.klass.find_by(reflection.klass.primary_key => foreign_key)
      end

      # Grants store the polymorphic base_class, so identity must too — otherwise
      # an STI parent and its base would read as different records and a loop
      # through them would not be seen.
      def identity(record)
        [ record.class.base_class.name, record.id ]
      end

      # Truncation denies rather than allows, so it can never escalate — but a
      # denial nobody can explain is its own failure, hence the warning.
      #
      # The latch keys on the KIND (:loop / :depth), never on the rendered chain:
      # the chain text carries record ids, so keying on it would mean a fresh
      # entry per record — a warning on every row and a Set that grows without
      # bound in a long-running process. At most two entries per class.
      def warn_truncated(record, kind, chain)
        key = [ record.class.base_class.name, kind ]
        return if warned.include?(key)

        warned << key
        reason = kind == :loop ? "a loop in the data" : "a chain longer than #{MAX_PARENT_DEPTH}"
        Rails.logger&.warn(
          "[CurrentScope] current_scope_parent stopped walking #{record.class.name} " \
          "early because of #{reason} (#{chain_text(chain)}). Grants held above that " \
          "point will not match, so this can only DENY, never allow. Fix the data (or " \
          "shorten the chain) if a subject is missing access they should have."
        )
      end

      def chain_text(keys)
        keys.map { |type, id| "#{type}##{id}" }.join(" -> ")
      end

      # A host that writes `def current_scope_parent = project` has written a
      # method that nothing calls: the declaration is a class macro. Every other
      # current_scope_* hook IS an instance method, so this is the mistake the
      # name invites, and silence would be indistinguishable from "flat by
      # design". This one DOES raise: it is a declaration error, reachable only
      # by writing it, and no row value can trigger it.
      def reject_method_form!(klass)
        return unless klass.method_defined?(:current_scope_parent)

        raise ConfigurationError,
              "#{klass.name} defines an INSTANCE method " \
              "`current_scope_parent`, but the declaration is a class-level macro " \
              "and nothing reads that method. Replace it with " \
              "`current_scope_parent :the_association` in the class body."
      end
    end
  end
end
