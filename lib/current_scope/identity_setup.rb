require "yaml"

module CurrentScope
  # Guided attach for #158. Dry-run by default; WRITE=1 calls grant!.
  # PLACEHOLDER=1 may create a marked stand-in outside production only.
  class IdentitySetup
    class Halt < StandardError; end

    def initialize(env: ENV, stdin: $stdin, stdout: $stdout)
      @env = env
      @stdin = stdin
      @stdout = stdout
    end

    def run
      apply_identity_override!
      report_collisions!
      subject = resolve_or_placeholder!
      role = prepare_role
      print_plan(subject, role)
      return unless write?

      CurrentScope.grant!(subject, role: role)
      say "Granted #{role.name} to #{portable_key.inspect} (#{subject.class}##{subject.id})."
    ensure
      restore_identity_override!
    end

    def collisions
      resolver = CurrentScope.config.subject_identity_resolver
      return [] if resolver.primary_key?

      resolver.colliding_keys
    end

    private

    def apply_identity_override!
      override = identity_from_env_or_prompt
      return if override.nil?

      @previous_identity = CurrentScope.config.subject_identity
      @overrode_identity = true
      CurrentScope.config.subject_identity = override
    end

    def restore_identity_override!
      return unless @overrode_identity

      CurrentScope.config.subject_identity = @previous_identity
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
      key = portable_key
      found = CurrentScope.resolve_subject(key)
      return found if found

      if placeholder?
        fail_if_production_placeholder!
        created = materialize_placeholder(key)
        say "Created placeholder #{created.class}##{created.id} marked #{SubjectIdentity::PLACEHOLDER_MARK}."
        return created
      end

      fail! "No subject resolved for #{key.inspect}. Production never invents one. " \
            "Outside production, re-run with PLACEHOLDER=1 after generating " \
            "`bin/rails generate current_scope:identity`."
    end

    def materialize_placeholder(key)
      SubjectIdentity.materialize_placeholder!(key, factory: placeholder_factory)
    rescue ConfigurationError => e
      fail! e.message
    end

    def portable_key
      raw = @env["SUBJECT"].presence
      raw = ask("Portable subject key: ") if raw.blank? && interactive?
      fail! "SUBJECT is required, e.g. SUBJECT=ada@example.com" if raw.blank?

      identity = CurrentScope.config.subject_identity
      if identity.is_a?(Array) && identity.size > 1
        parsed = YAML.safe_load(raw)
        unless parsed.is_a?(Array)
          fail! "SUBJECT for a composite identity must be a YAML sequence, " \
                "e.g. SUBJECT='[Ada, ada@example.com]'."
        end
        return parsed
      end

      raw
    end

    def prepare_role
      name = @env.fetch("ROLE", "Owner")
      if name == "Owner"
        CurrentScope.seed_defaults!
        return Role.find_by!(name: "Owner")
      end

      Role.find_or_create_by!(name: name)
    end

    def print_plan(subject, role)
      access = role.full_access? ? "yes" : "no"
      say "Identity: #{CurrentScope.config.subject_identity.inspect}"
      say "Subject: #{portable_key.inspect} → #{subject.class}##{subject.id}"
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

    def placeholder_factory
      raw = CurrentScope.config.subject_identity
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
