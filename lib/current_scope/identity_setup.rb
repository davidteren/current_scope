require "yaml"

module CurrentScope
  # Guided attach for #158. Dry-run by default; WRITE=1 calls grant!.
  # PLACEHOLDER=1 WRITE=1 may create a marked stand-in outside production only.
  # IDENTITY= compiles a local resolver and does not rewrite CurrentScope.config.
  class IdentitySetup
    class Halt < StandardError; end

    def initialize(env: ENV, stdin: $stdin, stdout: $stdout)
      @env = env
      @stdin = stdin
      @stdout = stdout
    end

    def run
      compile_identity_override!
      report_collisions!
      subject = resolve_or_placeholder!
      pending_placeholder = subject.equal?(:pending_placeholder)
      subject = nil if pending_placeholder
      role = prepare_role(persist: false)
      warn_if_replacing(subject, role)
      print_plan(subject, role)
      return unless write?

      RoleAssignment.transaction do
        if pending_placeholder
          subject = resolver.resolve(portable_key)
          if subject.nil?
            subject = materialize_placeholder(portable_key)
            say "Created placeholder #{subject.class}##{subject.id} marked #{SubjectIdentity::PLACEHOLDER_MARK}."
          end
        end
        fail! "No subject to grant." if subject.nil?

        role = prepare_role(persist: true)
        CurrentScope.grant!(subject, role: role)
        say "Granted #{role.name} to #{portable_key.inspect} (#{subject.class}##{subject.id})."
      end
    end

    # The colliding keys themselves, or [] when there are none to list. Read
    # only, and it never prompts: identity:check is a diagnostic that has to be
    # runnable from CI, cron, and a deploy hook, where a blocking $stdin.gets
    # is not a question — it is a hang.
    def collisions
      compile_identity_override!(prompt: false)
      return [] if resolver.primary_key?

      resolver.colliding_keys
    end

    # Asked separately from collisions, because "not unique" and "here are the
    # duplicates" are different facts. A host resolver may report a duplicate
    # and be unable to name one. That case used to be reported as the literal
    # colliding key "(duplicate natural key)", which reads in the output as a
    # natural key someone actually stored.
    def unique?
      compile_identity_override!(prompt: false)
      resolver.primary_key? || resolver.unique?
    end

    # What was actually audited. IDENTITY= overrides config.subject_identity for
    # one run, so "unique" on its own does not tell the operator which identity
    # earned that answer.
    def identity
      compile_identity_override!(prompt: false)
      declared_identity
    end

    private

    def compile_identity_override!(prompt: true)
      return if defined?(@identity_compiled)

      @identity_compiled = true
      override = identity_from_env_or_prompt(prompt: prompt)
      return if override.nil?

      @override_identity = override
      @override_resolver = SubjectIdentity.compile(
        override, klass: CurrentScope.config.resolved_subject_class
      )
    end

    def resolver
      @override_resolver || CurrentScope.config.subject_identity_resolver
    end

    def declared_identity
      @override_identity.nil? ? CurrentScope.config.subject_identity : @override_identity
    end

    def identity_from_env_or_prompt(prompt:)
      raw = @env["IDENTITY"].presence
      raw = ask("Identity column(s) (email or name,email): ") if prompt && raw.blank? && interactive?
      return if raw.blank?

      parts = raw.split(",").map { |part| part.strip.to_sym }
      parts.one? ? parts.first : parts
    end

    # unique? first, because it is the cheap question: a column identity
    # answers it from its unique index without touching the subject table, and
    # otherwise from the one scan colliding_keys.empty? already does. Asking
    # for the list first would scan even where an index made that unnecessary.
    def report_collisions!
      return if unique?

      keys = collisions
      if keys.any?
        sample = keys.first(5).map(&:inspect).join(", ")
        fail! "Identity is not unique (#{keys.size} colliding key(s): #{sample}). " \
              "No grant was written."
      end

      fail! "Identity is not unique: the configured resolver reports a duplicate " \
            "but does not list the colliding keys. No grant was written."
    end

    def resolve_or_placeholder!
      fail_if_production_placeholder! if placeholder?

      key = portable_key
      found = resolver.resolve(key)
      return found if found

      if placeholder?
        require_placeholder_factory!
        unless write?
          say "Would create a placeholder marked #{SubjectIdentity::PLACEHOLDER_MARK} " \
              "for #{key.inspect}."
          return nil
        end

        return :pending_placeholder
      end

      fail! "No subject resolved for #{key.inspect}. Production never invents one. " \
            "Outside production, re-run with PLACEHOLDER=1 WRITE=1 after generating " \
            "`bin/rails generate current_scope:identity`."
    end

    # No transaction of its own. The only caller already opened one in `run`,
    # and a nested block WITHOUT requires_new: true is not a savepoint — it
    # joins the outer transaction and reads as protection that is not there.
    # A fail! here still rolls the placeholder back, through the outer one.
    def materialize_placeholder(key)
      created = placeholder_factory.call(key)
      klass = CurrentScope.config.resolved_subject_class
      unless klass && created.is_a?(klass)
        fail! "placeholder factory returned #{created.class}, expected #{klass}."
      end

      identified = resolver.identify(created)
      unless identified == key || Array(identified) == Array(key)
        fail! "placeholder factory produced #{identified.inspect}, expected #{key.inspect}."
      end

      created
    end

    def portable_key
      return @portable_key if defined?(@portable_key)

      raw = @env["SUBJECT"].presence
      raw = ask("Portable subject key: ") if raw.blank? && interactive?
      fail! "SUBJECT is required, e.g. SUBJECT=ada@example.com" if raw.blank?

      identity = declared_identity
      @portable_key = if identity.is_a?(Array) && identity.size > 1
        parse_composite_key(raw)
      else
        raw
      end
    end

    def parse_composite_key(raw)
      parsed = YAML.safe_load(raw)
      fail! composite_hint unless parsed.is_a?(Array)

      columns = declared_identity
      unless parsed.size == columns.size
        fail! "SUBJECT gave #{parsed.size} value(s), but config.subject_identity " \
              "names #{columns.size}: #{columns.map(&:inspect).join(', ')}. #{composite_hint}"
      end

      values = parsed.map { |value| value.nil? ? value : value.to_s }
      if values.any? { |value| SubjectIdentity.blank_value?(value) }
        fail! "SUBJECT #{values.inspect} has a blank part. A blank part is not a " \
              "portable identity — no subject can be resolved by it."
      end

      values
    # Psych::Exception, not Psych::SyntaxError: safe_load also raises
    # Psych::DisallowedClass for input that PARSES and then builds a refused
    # type, e.g. SUBJECT='[2026-01-01, x]', which it tries to make a Date.
    # That is operator input, so it deserves the operator message, not a
    # stack trace. fail! raises Halt, which is not a Psych::Exception.
    rescue Psych::Exception
      fail! composite_hint
    end

    def composite_hint
      "SUBJECT for a composite identity must be a YAML sequence, " \
        "e.g. SUBJECT='[Ada, ada@example.com]'."
    end

    def prepare_role(persist:)
      name = @env["ROLE"].presence || "Owner"
      if persist
        if name == "Owner"
          CurrentScope.seed_defaults!
          return Role.find_by!(name: "Owner")
        end
        return Role.find_or_create_by!(name: name)
      end

      Role.find_by(name: name) || Role.new(name: name, full_access: name == "Owner")
    end

    def warn_if_replacing(subject, role)
      return if subject.nil?

      prior = RoleAssignment.find_by(subject: subject)&.role
      return if prior.nil? || prior.name == role.name

      warn "WARNING: #{subject.class}##{subject.id} already held the #{prior.name.inspect} role — " \
           "replacing it with #{role.name}."
    end

    def print_plan(subject, role)
      access = role.full_access? ? "yes" : "no"
      say "Identity: #{declared_identity.inspect}"
      if subject
        say "Subject: #{portable_key.inspect} → #{subject.class}##{subject.id}"
      else
        say "Subject: #{portable_key.inspect} → (would create placeholder)"
      end
      say "Role: #{role.name} (full_access: #{access})"
      say "Would grant #{role.name} to #{portable_key.inspect}."
      say "Dry-run only. Re-run with WRITE=1 to grant." unless write?
    end

    def write? = @env["WRITE"] == "1"

    def placeholder? = @env["PLACEHOLDER"] == "1"

    def fail_if_production_placeholder!
      return unless SubjectIdentity.production?

      fail! "PLACEHOLDER=1 is refused in production. No subject was created."
    end

    def require_placeholder_factory!
      return if placeholder_factory

      # Naming the override matters: the host may have a working factory on
      # config.subject_identity and be told it has none, because IDENTITY=
      # replaced that object with a plain column for this run.
      if @override_identity
        fail! "PLACEHOLDER=1 has no factory: IDENTITY=#{@override_identity.inspect} " \
              "replaced config.subject_identity for this run, and a column identity " \
              "has no create_placeholder!. Drop IDENTITY= to use the configured " \
              "identity object and its factory."
      end

      fail! "PLACEHOLDER=1 has no factory. Generate `bin/rails generate " \
            "current_scope:identity` and implement create_placeholder!(key) " \
            "on that object, stamped with #{SubjectIdentity::PLACEHOLDER_MARK.inspect}."
    end

    def placeholder_factory
      raw = declared_identity
      return ->(key) { raw.create_placeholder!(key) } if raw.respond_to?(:create_placeholder!)

      nil
    end

    def interactive? = @stdin.respond_to?(:tty?) && @stdin.tty?

    def ask(prompt)
      @stdout.print prompt
      @stdin.gets&.strip
    end

    def say(message) = @stdout.puts(message)

    def fail!(message) = raise(Halt, message)
  end
end
