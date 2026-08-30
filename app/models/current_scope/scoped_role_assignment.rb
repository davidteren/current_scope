module CurrentScope
  # A role held on ONE specific record: "Editor of Project #7" grants nothing
  # on Project #8. Never touches the subject's org-wide role — the two are
  # independent axes.
  #
  # Rows survive host resource destruction by design (polymorphic, no
  # dependent:). Since #65 those orphan grants open nothing (empty list = 403)
  # but still rendered like live access until labeled (#90).
  class ScopedRoleAssignment < ApplicationRecord
    belongs_to :role
    belongs_to :subject, polymorphic: true
    belongs_to :resource, polymorphic: true

    validates :role_id, uniqueness: {
      scope: [ :subject_type, :subject_id, :resource_type, :resource_id ]
    }

    # #183: a type may declare which roles are grantable on it. The gate, as
    # opposed to the console's filtering, because a grant can be written by a
    # seed, a rake task or a console one-liner and every one of those has to
    # meet the same rule.
    validate :role_grantable_on_resource_type

    # #151: a grant must name exactly one record on BOTH sides.
    include CurrentScope::StorableKeys
    validates_storable_polymorphic_keys "subject", "resource"

    # Batch-load polymorphic resources for resolvable types only. A global
    # includes(:resource) NameErrors when any resource_type is stale; this
    # constantizes per type and skips unresolvable ones so they stay lazy
    # and orphaned_resource? labels them inert (#90 / PR #104 review).
    def self.preload_resolvable_resources!(assignments)
      list = Array(assignments)
      return list if list.empty?

      list.group_by(&:resource_type).each do |type, rows|
        next if type.blank?

        # Same canonical resolver the key guard uses: a namespaced, shortened or
        # custom polymorphic token must not read as missing here while passing
        # validation there.
        klass = CurrentScope.polymorphic_class(type, inert_on_error: true)
        next if klass.nil?
        next unless klass.respond_to?(:where)

        # Look up by the DECLARED primary key, and index on the string form of it.
        # resource_id is a string column (#151), so a record keyed on an integer
        # yields 1 while the grant holds "1"; matching them raw silently misses and
        # labels a live grant inert. `where` casts the strings back to the column's
        # own type, so the query is still correct on every adapter.
        key = klass.primary_key
        unless key.is_a?(String)
          mark_resources_loaded(rows, {})
          next
        end

        # Only ids that are legal keys for THIS model reach the query. A legacy
        # collapsed value ("7", left by the pre-#151 integer column) sent at a
        # PostgreSQL uuid column does not come back empty — it RAISES
        # `invalid input syntax for type uuid`, and the console page an
        # administrator opens to find these very grants 500s instead of listing
        # them as inert. Same rule the resolver applies (CurrentScope
        # .canonical_key?); a dropped id simply stays unloaded, which is exactly
        # what orphaned_resource? then labels.
        ids = rows.map(&:resource_id).uniq.select { |id| CurrentScope.canonical_key?(klass, id) }

        # When NOTHING in the group is a legal key, skip the query but still mark
        # every row loaded-as-nil below. Returning early instead would leave the
        # associations lazy, so the first orphaned_resource? call would go and do
        # per-row exactly the load this method exists to do safely and in bulk.
        records = ids.empty? ? {} : klass.where(key => ids).index_by { |r| r[key].to_s }
        mark_resources_loaded(rows, records)
      end

      list
    end

    # True when the pointed-at resource is gone (deleted row or unresolvable
    # type). The grant is inert for authorization (#65) but still a console row.
    # Memoized: views call this plus the label helper once each; a reset-every-
    # call would re-query the resource twice per row (PR #104 cubic follow-up).
    def orphaned_resource?
      return @orphaned_resource if defined?(@orphaned_resource)

      @orphaned_resource =
        if resource_id.blank?
          false
        else
          current_scope_resolved_record("resource").nil?
        end
    rescue NameError, ActiveRecord::RecordNotFound
      @orphaned_resource = true
    end

    def self.mark_resources_loaded(rows, records)
      rows.each do |row|
        assoc = row.association(:resource)
        assoc.target = records[row.resource_id.to_s]
        assoc.loaded!
      end
    end
    private_class_method :mark_resources_loaded

    private

    # Silent unless the type opted in (#183): with no declaration every role
    # stays grantable on every type, which is what every existing host has.
    #
    # An unresolvable type is left alone — the storable-key guard and the
    # polymorphic registry already own that question, and answering it twice
    # with two messages helps nobody.
    def role_grantable_on_resource_type
      return if role.nil? || resource_type.blank?

      # The record's OWN class when it is loaded, and only then the token's.
      # CurrentScope.polymorphic_class always answers with the BASE class — the
      # registry claims each token with klass.base_class, and an STI grant
      # stores the base token — so asking it would make a declaration on an STI
      # subclass a silent no-op while the module, the guide and the reader all
      # promise it is inherited and overridable (#183 review).
      #
      # Through the CHECKED reader, never the raw association: a non-canonical
      # stored id casts into an unrelated live record, and the gate would then
      # judge (and name) the wrong class — the one call site that read the plain
      # association is this one (#183 review, #151).
      klass = current_scope_resolved_record("resource")&.class ||
              CurrentScope.polymorphic_class(resource_type, inert_on_error: true)
      return if klass.nil? || !klass.respond_to?(:current_scope_grants_role?)
      return if klass.current_scope_grants_role?(role)

      # Read through respond_to? and Array(): the type joins this gate by
      # answering current_scope_grants_role? alone, which a host may compute
      # without holding a list at all (#183 review).
      allowed = Array(klass.try(:current_scope_grantable_roles))
      accepts = if allowed.empty?
        "it accepts no scoped roles at all"
      else
        "it accepts #{allowed.to_sentence(two_words_connector: ' or ', last_word_connector: ' or ')}"
      end
      errors.add(:role, "cannot be granted on #{klass.name}: #{accepts}")
    end
  end
end
