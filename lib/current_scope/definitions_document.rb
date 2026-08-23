require "fileutils"
require "yaml"

module CurrentScope
  # Desired-state YAML for role definitions (names, descriptions, full_access,
  # permission-key sets). Assignments are not in this document (#156 v1).
  class DefinitionsDocument
    API_VERSION = "current_scope/definitions-v1"

    class Error < StandardError; end
    class ConfirmRequired < Error; end
    class InvalidDocument < Error; end
    class LastHolderLock < Error; end
    class HeldRoleDelete < Error; end
    class UnknownCatalogKey < Error; end
    class SnapshotMissing < Error; end

    RoleSpec = Data.define(:name, :description, :full_access, :permission_keys)
    RemovedRole = Data.define(:name, :org_holders, :scoped_holders)
    RoleChange = Data.define(
      :name, :full_access_from, :full_access_to,
      :description_from, :description_to, :keys_added, :keys_removed
    )

    class Diff
      attr_reader :added, :removed, :changes

      def initialize(added:, removed:, changes:)
        @added = added
        @removed = removed
        @changes = changes
      end

      def empty?
        added.empty? && removed.empty? && changes.empty?
      end

      def added_names
        added.map(&:name)
      end

      def removed_names
        removed.map(&:name)
      end

      def change_for(name)
        changes.find { |change| change.name == name }
      end

      def removed_for(name)
        removed.find { |role| role.name == name }
      end

      # Removals, then FA demotions, then key removals, then adds.
      def to_s
        lines = []
        removed.each do |role|
          lines << "remove role #{role.name} (#{role.org_holders} org holders, #{role.scoped_holders} scoped holders)"
        end
        changes.each do |change|
          if change.full_access_from && !change.full_access_to
            lines << "role #{change.name} full_access false"
          end
        end
        changes.each do |change|
          change.keys_removed.each { |key| lines << "role #{change.name} loses #{key}" }
        end
        added.each do |role|
          flag = role.full_access ? " full_access true" : ""
          lines << "add role #{role.name}#{flag}"
        end
        changes.each do |change|
          change.keys_added.each { |key| lines << "role #{change.name} gains #{key}" }
          if !change.full_access_from && change.full_access_to
            lines << "role #{change.name} full_access true"
          end
          if change.description_from != change.description_to
            lines << "role #{change.name} description changed"
          end
        end
        lines.join("\n")
      end
    end

    def self.from_live
      specs = Role.order(:name).includes(:role_permissions).map do |role|
        RoleSpec.new(
          name: role.name,
          description: role.description.to_s,
          full_access: role.full_access?,
          permission_keys: role.role_permissions.map(&:permission_key).sort
        )
      end
      new(specs)
    end

    def self.parse(source)
      data = load_source(source)
      raise InvalidDocument, "document is empty" if data.nil? || data == false
      raise InvalidDocument, "document must be a mapping" unless data.is_a?(Hash)

      version = data["apiVersion"] || data[:apiVersion]
      unless version == API_VERSION
        raise InvalidDocument,
              "Missing or unsupported apiVersion (need #{API_VERSION})."
      end

      raw_roles = data["roles"] || data[:roles]
      raise InvalidDocument, "roles must be a list" unless raw_roles.is_a?(Array)

      specs = raw_roles.map { |row| spec_from(row) }
      names = specs.map(&:name)
      if names.size != names.uniq.size
        raise InvalidDocument, "duplicate role name in document"
      end

      # The file we were read from, if any: write_snapshot must never overwrite
      # it. File.file? is the same test load_source used to pick this branch.
      from_file = source.is_a?(Pathname) ||
                  (source.is_a?(String) && !source.include?("\n") && File.file?(source))
      new(specs, source_path: (source.to_s if from_file))
    end

    def self.load_source(source)
      case source
      when Hash
        stringify_keys(source)
      when Pathname
        raise SnapshotMissing, "No snapshot at #{source}" unless source.exist?

        YAML.safe_load(source.read, permitted_classes: [], aliases: false)
      when DefinitionsDocument
        stringify_keys(source.to_h)
      when String
        if source.include?("\n") || source.start_with?("---")
          YAML.safe_load(source, permitted_classes: [], aliases: false)
        elsif File.file?(source)
          YAML.safe_load(File.read(source), permitted_classes: [], aliases: false)
        else
          raise SnapshotMissing, "No file at #{source}"
        end
      else
        raise InvalidDocument, "cannot parse #{source.class}"
      end
    # Psych::Exception, not Psych::SyntaxError: safe_load also refuses input
    # that PARSES, e.g. a YAML anchor/alias or a tagged value. Those are
    # operator documents, so they deserve InvalidDocument, not a backtrace.
    rescue Psych::Exception => e
      raise InvalidDocument, e.message
    end
    private_class_method :load_source

    def self.spec_from(row)
      raise InvalidDocument, "each role must be a mapping" unless row.is_a?(Hash)

      row = stringify_keys(row)
      name = row["name"].to_s
      raise InvalidDocument, "role name is required" if name.blank?

      keys = Array(row["permission_keys"]).map(&:to_s).reject(&:blank?).uniq.sort
      full_access = row.fetch("full_access", false)
      # No permissive cast. Boolean.new.cast turns every unrecognised value into
      # true, so a typo ("ture", "yes", an empty key) would grant full access.
      unless [ true, false ].include?(full_access)
        raise InvalidDocument, "role #{name}: full_access must be true or false"
      end
      RoleSpec.new(
        name: name,
        description: row["description"].to_s,
        full_access: full_access,
        permission_keys: keys
      )
    end
    private_class_method :spec_from

    def self.stringify_keys(hash)
      hash.to_h { |key, value| [ key.to_s, value ] }
    end
    private_class_method :stringify_keys

    def self.default_snapshot_path
      Rails.root.join("tmp/current_scope/last_definitions_snapshot.yml").to_s
    end

    def initialize(roles, source_path: nil)
      @roles = Array(roles).sort_by(&:name)
      @source_path = source_path
    end

    def roles
      @roles
    end

    def to_h
      {
        "apiVersion" => API_VERSION,
        "roles" => @roles.map do |role|
          {
            "name" => role.name,
            "description" => role.description,
            "full_access" => role.full_access,
            "permission_keys" => role.permission_keys
          }
        end
      }
    end

    def to_yaml
      YAML.dump(to_h)
    end

    def diff(other = nil)
      live = other || self.class.from_live
      live_by_name = live.roles.index_by(&:name)
      doc_by_name = @roles.index_by(&:name)

      added = @roles.reject { |role| live_by_name.key?(role.name) }
      missing = live.roles.reject { |role| doc_by_name.key?(role.name) }
      live_removed = Role.where(name: missing.map(&:name)).index_by(&:name)
      removed = missing.map do |role|
        record = live_removed[role.name]
        RemovedRole.new(
          name: role.name,
          org_holders: record ? record.role_assignments.count : 0,
          scoped_holders: record ? record.scoped_role_assignments.count : 0
        )
      end
      changes = []
      @roles.each do |spec|
        current = live_by_name[spec.name]
        next unless current

        keys_added = spec.permission_keys - current.permission_keys
        keys_removed = current.permission_keys - spec.permission_keys
        next if spec.full_access == current.full_access &&
                spec.description == current.description &&
                keys_added.empty? && keys_removed.empty?

        changes << RoleChange.new(
          name: spec.name,
          full_access_from: current.full_access,
          full_access_to: spec.full_access,
          description_from: current.description,
          description_to: spec.description,
          keys_added: keys_added,
          keys_removed: keys_removed
        )
      end

      Diff.new(added: added, removed: removed, changes: changes)
    end

    def apply(confirm: false, actor: nil, subject: nil, snapshot_path: nil, event: "definitions.applied")
      unknown = @roles.flat_map(&:permission_keys).uniq.reject { |key| CurrentScope.catalog.include?(key) }
      unless unknown.empty?
        raise UnknownCatalogKey,
              "Permission keys not in the catalog: #{unknown.join(', ')}"
      end

      changeset = diff
      return changeset if changeset.empty?

      if confirm_required? && confirm != true
        raise ConfirmRequired,
              "Confirm is required to apply role definitions on a populated or " \
              "production database. Pass confirm: true (API) or CONFIRM=1 (rake)."
      end

      if CurrentScope.config.audit
        actor ||= CurrentScope::Current.actor
        if actor.nil?
          raise CurrentScope::ConfigurationError,
                "CurrentScope::Event.record! has no actor — CurrentScope::Current.actor is nil. " \
                "Set the ambient context (the controller hook, or with_current_user in tests) before recording."
        end
      end

      path = snapshot_destination(snapshot_path)
      previous_snapshot = File.exist?(path) ? File.read(path) : nil
      wrote_snapshot = false
      committed = false

      begin
        Role.transaction do
          planned_fa = @roles.select(&:full_access).map(&:name)
          FullAccessLock.lock_console_state!(planned_fa)
          refuse_held_deletes!
          if FullAccessLock.would_lose_held_full_access?(planned_fa)
            raise LastHolderLock,
                  "Refusing to apply: this document would leave zero org-wide full-access holders."
          end

          write_snapshot(path)
          wrote_snapshot = true
          persist_roles!
          if CurrentScope.config.audit
            Event.record!(
              event: event,
              target: CurrentScope::Event::DEFINITIONS_TARGET,
              details: {
                "snapshot" => path,
                "diff" => changeset.to_s
              },
              actor: actor,
              subject: subject || actor
            )
          end
        end
        committed = true
      ensure
        # The snapshot is written inside the transaction so an unwritable path
        # stops the apply. An apply that does not commit changed nothing, so put
        # back what the undo file held: the previous apply's undo point. Only
        # what THIS run wrote, and an ensure rather than a rescue because Ctrl-C
        # is not a StandardError.
        restore_snapshot(path, previous_snapshot) if wrote_snapshot && !committed
      end

      changeset
    end

    def confirm_required?
      Rails.env.production? || Role.exists?
    end

    # Where this apply writes its undo file. Never the document being applied: a
    # rollback reading the default snapshot path would otherwise overwrite it
    # with the state it is undoing, so running rollback twice would re-apply it.
    # File.identical?, not a path compare: a symlink or a case-variant spelling
    # is the same file under two names.
    def snapshot_destination(snapshot_path)
      path = (snapshot_path.presence || self.class.default_snapshot_path).to_s
      return path unless @source_path && File.identical?(path, @source_path)

      "#{path}.pre.yml"
    end

    private

    def refuse_held_deletes!
      doc_names = @roles.map(&:name)
      Role.where.not(name: doc_names).find_each do |role|
        org = role.role_assignments.count
        scoped = role.scoped_role_assignments.count
        next if org.zero? && scoped.zero?

        raise HeldRoleDelete,
              "Refusing to delete role #{role.name}: it still has #{org} org-wide " \
              "and #{scoped} scoped holders."
      end
    end

    def persist_roles!
      doc_names = @roles.map(&:name)
      live = Role.all.index_by(&:name)

      @roles.each do |spec|
        role = live[spec.name] || Role.new(name: spec.name)
        role.description = spec.description
        role.full_access = spec.full_access
        role.permission_keys = spec.permission_keys
        role.save!
      end

      (live.keys - doc_names).each { |name| live[name].destroy! }
    end

    # A failure here must never replace the error that stopped the apply.
    def restore_snapshot(path, previous)
      previous ? File.write(path, previous) : FileUtils.rm_f(path)
    rescue StandardError => e
      Rails.logger&.warn("[current_scope] could not restore the role definitions snapshot at #{path}: #{e.message}")
      nil
    end

    def write_snapshot(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, self.class.from_live.to_yaml)
      path
    end
  end
end
