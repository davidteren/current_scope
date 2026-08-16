module CurrentScope
  # Portable subject identity (#158). Grants still store the storable primary
  # key; this layer maps a host-declared natural key onto that row so a later
  # assignment import can find the same person in another environment.
  #
  # Sugar (Symbol / Array of symbols) compiles to a resolver. A host object
  # that responds to identify/resolve is used as-is. A String, Proc, or lambda
  # pair is rejected — that shape belongs to subject_label, which is display
  # only and fail-soft. Identity is load-bearing and fail-loud.
  module SubjectIdentity
    # Grep-able mark stamped on a non-production stand-in so operators can
    # find leftover rows. Never written by resolve itself.
    PLACEHOLDER_MARK = "current_scope_placeholder"

    def self.compile(value, klass:)
      case value
      when nil
        PrimaryKeyResolver.new(klass)
      when Symbol
        column_or_primary(klass, [ value ])
      when Array
        if value.empty?
          raise ConfigurationError,
                "config.subject_identity = [] is empty. Name at least one column, " \
                "or leave the default (the primary key)."
        end
        unless value.all? { |column| column.is_a?(Symbol) }
          raise ConfigurationError,
                "config.subject_identity = #{value.inspect} must be an Array of " \
                "Symbols (for example [:name, :email]). This is not subject_label."
        end
        column_or_primary(klass, value)
      when String
        raise ConfigurationError,
              "config.subject_identity = #{value.inspect} is a String. Write " \
              ":#{value} (a Symbol) for a column. A String is rejected so this " \
              "knob cannot be confused with config.subject_label."
      when Proc
        raise ConfigurationError,
              "config.subject_identity does not accept a Proc. Supply an object " \
              "that responds to identify(subject) and resolve(key). " \
              "config.subject_label is the fail-soft display knob; identity is not."
      else
        unless value.respond_to?(:identify) && value.respond_to?(:resolve)
          raise ConfigurationError,
                "config.subject_identity = #{value.inspect} is not a supported " \
                "shape. Use a Symbol (one column), an Array of symbols (a " \
                "composite), or an object that responds to identify(subject) and " \
                "resolve(key). A String, Proc, or lambda pair is rejected — this " \
                "is not config.subject_label."
        end
        HostResolver.new(value)
      end
    end

    # Production never invents a subject. Non-production placeholder is an
    # explicit tooling mode: resolve stays pure and never inserts.
    def self.materialize_placeholder!(key, factory:)
      if production?
        raise ConfigurationError,
              "PLACEHOLDER mode is refused in production. resolve returned no " \
              "subject for #{key.inspect} and CurrentScope will not invent one."
      end

      existing = CurrentScope.resolve_subject(key)
      return existing if existing

      if factory.nil?
        raise ConfigurationError,
              "PLACEHOLDER=1 has no factory. Generate `bin/rails generate " \
              "current_scope:identity` and implement create_placeholder!(key) " \
              "on that object, stamped with #{PLACEHOLDER_MARK.inspect}."
      end

      created = nil
      CurrentScope::RoleAssignment.transaction do
        created = factory.call(key)
        klass = CurrentScope.config.resolved_subject_class
        unless klass && created.is_a?(klass)
          raise ConfigurationError,
                "placeholder factory returned #{created.class}, expected #{klass}."
        end

        identified = CurrentScope.identify_subject(created)
        unless identified == key || Array(identified) == Array(key)
          raise ConfigurationError,
                "placeholder factory produced #{identified.inspect}, expected #{key.inspect}."
        end
      end
      created
    end

    def self.production?
      defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?
    end

    def self.column_or_primary(klass, columns)
      if columns.size == 1 && klass && columns.first.to_s == klass.primary_key.to_s
        PrimaryKeyResolver.new(klass)
      else
        ColumnResolver.new(klass, columns)
      end
    end
    private_class_method :column_or_primary

    class PrimaryKeyResolver
      def initialize(klass)
        @klass = klass
      end

      def primary_key? = true

      def identify(subject)
        require_klass!
        subject.public_send(@klass.primary_key).to_s
      end

      def resolve(key)
        require_klass!
        return if key.blank?
        if key.is_a?(Array)
          raise ConfigurationError,
                "primary-key identity expects one value, got #{key.inspect}."
        end

        @klass.find_by(@klass.primary_key => key)
      end

      def unique? = true

      def colliding_keys = []

      private

      def require_klass!
        return if @klass

        raise ConfigurationError,
              "config.subject_class does not resolve, so the default primary-key " \
              "identity cannot identify or resolve a subject."
      end
    end

    # One column or a composite. identify of one column is a string; identify
    # of several is a frozen array of strings. Never a joined delimiter string.
    class ColumnResolver
      def initialize(klass, columns)
        @klass = klass
        @columns = columns.map(&:to_sym).freeze
      end

      def primary_key? = false

      def identify(subject)
        values = @columns.map { |column| stringify(subject.public_send(column)) }
        @columns.one? ? values.first : values.freeze
      end

      def resolve(key)
        attrs = attributes_for(key)
        return if attrs.nil?

        rows = relation.where(attrs).limit(2).to_a
        case rows.size
        when 0 then nil
        when 1 then rows.first
        else
          raise ConfigurationError,
                "config.subject_identity matched more than one #{relation.name} " \
                "for #{key.inspect}. resolve refuses a first-row win."
        end
      end

      def unique?
        colliding_keys.empty?
      end

      def colliding_keys
        @colliding_keys ||= begin
          assert_columns!
          colliding_groups.keys
        end
      end

      private

      def relation
        @klass || raise(ConfigurationError,
                        "config.subject_class does not resolve, so a column " \
                        "identity cannot query subjects.")
      end

      def attributes_for(key)
        return if key.nil?

        values = Array(key)
        return if values.size == 1 && values.first.to_s.strip.empty?
        if values.size != @columns.size
          raise ConfigurationError,
                "config.subject_identity expected #{@columns.size} value(s) for " \
                "#{@columns.inspect}, got #{key.inspect}."
        end
        return if values.any? { |value| value.nil? || value.to_s.strip.empty? }

        @columns.zip(values.map { |value| stringify(value) }).to_h
      end

      def stringify(value)
        value.nil? ? "" : value.to_s
      end

      def assert_columns!
        missing = @columns.reject { |column| relation.column_names.include?(column.to_s) }
        return if missing.empty?

        raise ConfigurationError,
              "config.subject_identity names #{missing.map(&:inspect).join(', ')} " \
              "but #{relation.name} has no such column."
      end

      def colliding_groups
        scope = relation.all
        @columns.each do |column|
          scope = scope.where.not(column => nil)
          scope = scope.where.not(column => "") if stringish?(column)
        end
        scope.group(*@columns).having("COUNT(*) > 1").count
      end

      def stringish?(column)
        info = relation.columns_hash[column.to_s]
        info.nil? || info.type.in?([ :string, :text ])
      end
    end

    class HostResolver
      def initialize(object)
        @object = object
      end

      def primary_key? = false

      def identify(subject) = @object.identify(subject)

      def resolve(key) = @object.resolve(key)

      # Boot does not invent a join scan (plan KTD-3). If the host does not
      # expose unique?, uniqueness is the host resolve contract: wrap a
      # first-row find_by and you can pick the wrong subject. Sugar resolvers
      # refuse that; a host object is used as-is.
      def unique?
        return true unless unique_checkable?

        @object.unique?
      end

      def unique_checkable? = @object.respond_to?(:unique?)

      def colliding_keys = []
    end
  end
end
