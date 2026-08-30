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

    # #151: a grant must name exactly one record on BOTH sides.
    include CurrentScope::StorableKeys
    validates_storable_polymorphic_keys "subject", "resource"

    # #182: every write path is audited, not only the console's. See
    # CurrentScope::AuditedWrites for why these are in-transaction callbacks and
    # how a write with no human behind it is attributed.
    include CurrentScope::AuditedWrites
    after_create :record_scoped_role_granted
    after_destroy :record_scoped_role_revoked

    # The audit TARGET is the subject, resolved through the canonical guard so a
    # non-canonical stored id names the grant row itself rather than the
    # unrelated live record that id would cast into (#151). The console used the
    # same rule; it lives here now so every path gets it.
    def audit_subject = current_scope_resolved_record("subject") || self

    # Label from the record while it is still there, else from the stored
    # type/id, so an audit row never 500s on a stale reference or on a host
    # label method that raises.
    def audit_resource_label
      resource = current_scope_resolved_record("resource")
      resource ? CurrentScope.label_for(resource) : "#{resource_type} ##{resource_id}"
    rescue StandardError
      "#{resource_type} ##{resource_id}"
    end

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

    def record_scoped_role_granted
      audit_write!("scoped_role.granted", target: audit_subject,
                                          details: { role: role.name, resource: audit_resource_label })
    end

    def record_scoped_role_revoked
      audit_write!("scoped_role.revoked", target: audit_subject,
                                          details: { role: role.name, resource: audit_resource_label })
    end
  end
end
