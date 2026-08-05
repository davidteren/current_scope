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
        klass = CurrentScope.polymorphic_class(type, owner: self)
        next if klass.nil?
        next unless klass.respond_to?(:where)

        # Look up by the DECLARED primary key, and index on the string form of it.
        # resource_id is a string column (#151), so a record keyed on an integer
        # yields 1 while the grant holds "1"; matching them raw silently misses and
        # labels a live grant inert. `where` casts the strings back to the column's
        # own type, so the query is still correct on every adapter.
        key = klass.primary_key
        next unless key.is_a?(String)

        records = klass.where(key => rows.map(&:resource_id).uniq)
                       .index_by { |r| r[key].to_s }
        rows.each do |row|
          assoc = row.association(:resource)
          assoc.target = records[row.resource_id.to_s]
          assoc.loaded!
        end
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
          resource.nil?
        end
    rescue NameError, ActiveRecord::RecordNotFound
      @orphaned_resource = true
    end
  end
end
