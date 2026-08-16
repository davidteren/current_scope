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
      role = prepare_role
      warn_if_replacing(subject, role)
      print_plan(subject, role)
      return unless write?

      RoleAssignment.transaction do
        if pending_placeholder
          subject = materialize_placeholder(portable_key)
          say "Created placeholder #{subject.class}##{subject.id} marked #{SubjectIdentity::PLACEHOLDER_MARK}."
        end
        fail! "No subject to grant." if subject.nil?

        CurrentScope.grant!(subject, role: role)
        say "Granted #{role.name} to #{portable_key.inspect} (#{subject.class}##{subject.id})."
      end
    end

    def collisions
      compile_identity_override!
      return [] if resolver.primary_key?

      keys = resolver.colliding_keys
      return keys if keys.any?
      return [ "(duplicate natural key)" ] unless resolver.unique?
      if resolver.respond_to?(:unique_checkable?) && !resolver.unique_checkable?
        return [ "(host object has no unique? — not scanned)" ]
      end

      []
    end

    private

    def compile_identity_override!
      return if defined?(@identity_compiled)

      @identity_compiled = true
      override = identity_from_env_or_prompt
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

    def identity_from_env_or_prompt
      raw = @env["IDENTITY"].presence
      raw = ask("Identity column(s) (email or name,email): ") if raw.blank? && interactive?
      return if raw.blank?

      parts = raw.split(",").map { |part| part.strip.to_sym }
      parts.one? ? parts.first : parts
    end

    def report_collisions!
      keys = collisions
      return if keys.empty?

      sample = keys.first(5).map(&:inspect).join(", ")
      fail! "Identity is not unique (#{keys.size} colliding key(s): #{sample}). " \
            "No grant was written."
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
      unless parsed.is_a?(Array)
        fail! "SUBJECT for a composite identity must be a YAML sequence, " \
              "e.g. SUBJECT='[Ada, ada@example.com]'."
      end
      parsed
    rescue Psych::SyntaxError
      fail! "SUBJECT for a composite identity must be a YAML sequence, " \
            "e.g. SUBJECT='[Ada, ada@example.com]'."
    end

    def prepare_role
      name = @env.fetch("ROLE", "Owner")
      if write?
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
