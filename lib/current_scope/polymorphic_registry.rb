module CurrentScope
  # Closed map from polymorphic storage token to base class (#155).
  #
  # Its own file rather than more of the facade, matching SchemaGuard and
  # ParentChain. CurrentScope.polymorphic_class / .storage_token /
  # .rebuild_polymorphic_registry! / .polymorphic_registry stay as thin
  # delegators.
  module PolymorphicRegistry
    class << self
      # The type string a grant stores for `klass`. Rails writes `polymorphic_name`,
      # not `base_class.name`. Collection queries must use the same token or a
      # custom name disappears from the list while the per-record gate still matches.
      def storage_token(klass)
        klass.polymorphic_name
      end

      # Resolve a stored polymorphic type token to its class. `*_type` is a Rails
      # STORAGE TOKEN, not necessarily a constant name: `polymorphic_name` can be
      # overridden and `store_full_class_name = false` shortens it, so
      # `safe_constantize` would return nil or resolve the wrong class.
      #
      # Returns nil for a token that no longer resolves, which callers treat as
      # "nothing to check" — a stale type is #90's inert grant, not a key problem.
      #
      # RAISES `ConfigurationError`, it does not return nil, when the registry is
      # poisoned (a rebuild found two classes claiming one token) or a live constant
      # disagrees with the registered owner on base_class. That is deliberate
      # fail-loud on a real misconfiguration, distinct from the nil-inert path: it
      # is caught at boot under eager_load and self-heals on the next dev reload, so
      # the request-path raise is only reachable in an eager-load-off environment.
      # Issue #166 landed here, because this method is the one place both raise
      # paths live. Inert-labeling callers now pass `inert_on_error: true` and get
      # nil, so the console degrades instead of 500ing. The raise still propagates
      # for every caller that does not ask, which is every WRITE path, and for the
      # last-holder guard, which must not read a refusal as "nobody holds this".
      # `inert_on_error: true` is for the labeling and preloading callers that
      # must never 500 the console (#166). It turns both raise paths into nil, so
      # the row degrades to inert through the SAME path a stale token already
      # takes, and records the cause on CurrentScope::Current so the console can
      # say why. Write paths never pass it: a grant must not be saved under a
      # registry that cannot say which class a token names.
      def class_for(type, inert_on_error: false)
        return if type.blank?
        raise @polymorphic_registry_error if @polymorphic_registry_error

        resolve_polymorphic_token(type.to_s)
      rescue ConfigurationError => e
        raise unless inert_on_error

        CurrentScope::Current.polymorphic_registry_error ||= e.message
        nil
      end

      # Rebuild the token → class map. Safe to call from to_prepare (dev reload)
      # and from after_initialize when eager_load is on. Enumeration is allowed
      # here; lookup is not.
      def rebuild!
        @polymorphic_registry_error = nil
        map = {}
        ActiveRecord::Base.descendants.each do |klass|
          next if klass.abstract_class?
          next unless klass.respond_to?(:polymorphic_name)

          token = klass.polymorphic_name.to_s
          next if token.blank?

          # Every loaded class occupies its token, including default names.
          # Skipping only custom overrides let Admin::User (token "User") sit
          # next to ::User without a raise, and then granted_ids aliased ids.
          # claim! is the single collision net. Default tokens in the map are
          # dead weight at lookup (Rails reverses them first) but keep one
          # structure instead of a parallel owners hash.
          claim!(map, token, klass.base_class)
        end
        CurrentScope.config.polymorphic_class_names.each do |token, class_name|
          token = token.to_s
          resolved = class_name.safe_constantize
          if resolved.nil?
            raise ConfigurationError,
                  "config.polymorphic_class_names maps #{token.inspect} to #{class_name.inspect}, " \
                  "which does not resolve to a class."
          end

          unless resolved.is_a?(Class) && resolved < ActiveRecord::Base && !resolved.abstract_class?
            raise ConfigurationError,
                  "config.polymorphic_class_names maps #{token.inspect} to #{class_name.inspect}, " \
                  "which is not a concrete Active Record model."
          end

          emitted = resolved.polymorphic_name.to_s
          if emitted != token
            raise ConfigurationError,
                  "config.polymorphic_class_names maps #{token.inspect} to #{resolved.name}, " \
                  "but #{resolved.name} stores #{emitted.inspect}."
          end

          claim!(map, token, resolved.base_class)
        end
        @polymorphic_registry = map.freeze
      rescue ConfigurationError => e
        @polymorphic_registry = {}.freeze
        @polymorphic_registry_error = e
        raise
      end

      def registry
        @polymorphic_registry ||= {}
      end

      # The latched rebuild failure, or nil. Public so the last-holder lock can
      # refuse to answer while the registry cannot say which class a token names
      # (#166): a guard that reads every holder as inert would report zero
      # holders and wave through the delete that locks everyone out.
      def error = @polymorphic_registry_error

      private

      def resolve_polymorphic_token(token)
        resolved = begin
          ActiveRecord::Base.polymorphic_class_for(token)
        rescue NameError
          nil
        end
        registered = registry[token]

        if resolved.is_a?(Class) && resolved < ActiveRecord::Base && !resolved.abstract_class? &&
           resolved.respond_to?(:polymorphic_name) &&
           resolved.polymorphic_name.to_s == token
          if registered && registered.base_class != resolved.base_class
            raise ConfigurationError,
                  "polymorphic token #{token.inspect} is claimed by both #{registered.name} " \
                  "and #{resolved.name}. Two classes cannot share a storage token."
          end
          # Prefer the registry's owner: the rebuild always stores base_class, so a
          # registered owner is the canonical (base) class. Rails could constantize
          # the token to a narrower STI subclass sharing that base; returning it
          # would apply the subclass STI predicate and mislabel sibling rows as
          # inert. They share a base_class here (checked above), so registered wins.
          return registered || resolved
        end

        registered
      end

      def claim!(map, token, klass)
        existing = map[token]
        if existing && existing != klass
          raise ConfigurationError,
                "polymorphic token #{token.inspect} is claimed by both #{existing.name} " \
                "and #{klass.name}. Two classes cannot share a storage token."
        end
        map[token] = klass
      end
    end
  end
end
