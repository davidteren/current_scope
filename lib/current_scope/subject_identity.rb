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

    # ONE definition of a blank identity value, for every caller. It used to be
    # written three times with two different answers: `attributes_for` stripped
    # whitespace, the uniqueness scan compared against '' in SQL and did not.
    # A "  " email was therefore a collision at boot and a non-key at resolve.
    def self.blank_value?(value)
      value.nil? || value.to_s.strip.empty?
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
        value = subject.public_send(@klass.primary_key)
        if SubjectIdentity.blank_value?(value)
          raise ConfigurationError,
                "#{subject.class} has no #{@klass.primary_key} yet, so it has no " \
                "portable identity. Save the record before identifying it."
        end

        value.to_s
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

      # Fail loud rather than mint a key that resolve will never find. identify
      # used to stringify nil to "", so a subject with a blank identity column
      # produced the key "" (or [ "Ada", "" ] for a composite) — and resolve
      # treats a blank part as no key at all and returns nil. An export would
      # have carried that dead key into the next environment silently.
      def identify(subject)
        raw = @columns.map { |column| subject.public_send(column) }
        blank = @columns.zip(raw).select { |_column, value| SubjectIdentity.blank_value?(value) }
        if blank.any?
          raise ConfigurationError,
                "#{subject.class}##{subject.id} has a blank " \
                "#{blank.map { |column, _value| column.inspect }.join(', ')}, which " \
                "config.subject_identity names. A blank part is not a portable " \
                "identity — resolve would never find this subject again. Fill the " \
                "column, or pick identity columns that are always present."
        end

        values = raw.map { |value| stringify(value) }
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

      def unique? = colliding_keys.empty?

      # The full list, and the ONE place the index fast path lives, so every
      # caller gets it — unique?, the boot error, and identity:check alike.
      # Putting it on unique? instead made the answer depend on which question
      # you asked first, which is how the task came to scan a table whose index
      # already proved the answer.
      #
      # Without an index this is a GROUP BY, and deliberately not a LIMITed
      # one: LIMIT bounds the groups RETURNED, not the rows read, so it buys
      # nothing from the database, and a limited page could be all blanks,
      # hiding a real duplicate behind them (see #171).
      #
      # NOT memoised, on purpose. This resolver is memoised on Configuration
      # and therefore lives as long as the process, so caching a scan here
      # made the answer a snapshot of whenever boot happened to run it —
      # current_scope:identity:check would then report boot's all-clear rather
      # than reading the table it was asked to audit. A diagnostic that
      # answers from a cache is worse than a slow one.
      def colliding_keys
        assert_columns!
        # A plain unique index proves there are none, without asking the table.
        return [] if unique_index?

        colliding_groups.keys
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
        return if values.size == 1 && SubjectIdentity.blank_value?(values.first)
        if values.size != @columns.size
          raise ConfigurationError,
                "config.subject_identity expected #{@columns.size} value(s) for " \
                "#{@columns.inspect}, got #{key.inspect}."
        end
        return if values.any? { |value| SubjectIdentity.blank_value?(value) }

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

      # Two rows whose shared value is only whitespace are not a collision,
      # because neither of them resolves in the first place.
      #
      # Ruby has the FINAL say on that, and the SQL is only a pre-filter. SQL
      # TRIM() removes spaces and nothing else, while Ruby's String#strip also
      # removes tabs, newlines, and the rest — so `TRIM(col) <> ''` leaves a
      # "\t" row standing that blank_value? calls blank. It never removes a row
      # Ruby would keep, which is the direction that matters: it can only ever
      # give Ruby less to reject, never a wrong answer. Rejecting in Ruby is
      # what makes the two agree exactly, on every adapter.
      def colliding_groups
        scope = relation.all
        @columns.each do |column|
          scope = scope.where.not(column => nil)
          scope = scope.where("TRIM(#{qualified(column)}) <> ''") if stringish?(column)
        end

        groups = scope.group(*@columns).having("COUNT(*) > 1").count
        groups.reject do |key, _count|
          Array(key).any? { |value| SubjectIdentity.blank_value?(value) }
        end
      end

      def qualified(column)
        "#{relation.quoted_table_name}.#{relation.connection.quote_column_name(column)}"
      end

      # A plain (non-partial) unique index on exactly these columns is the same
      # guarantee the scan computes, so take it and skip the scan. Any doubt
      # falls through to the scan, never past it: this may only ever turn a
      # slow YES into a fast YES.
      def unique_index?
        wanted = @columns.map(&:to_s).sort
        relation.connection.indexes(relation.table_name).any? do |index|
          index.unique && index.where.nil? &&
            Array(index.columns).map(&:to_s).sort == wanted
        end
      rescue StandardError
        false
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
