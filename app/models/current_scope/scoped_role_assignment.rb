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

    # #151: both ids land in integer columns, so a non-integer primary key on
    # EITHER side collapses distinct records into one grant identity.
    validate :polymorphic_keys_are_integer

    # Type column, not the association — see the note in RoleAssignment. Reading
    # `subject`/`resource` here would skip exactly the already-collapsed rows the
    # guard exists for, and would raise NameError on a stale type instead of
    # skipping it.
    def polymorphic_keys_are_integer
      { "subject" => subject_type, "resource" => resource_type }.each do |role, type|
        klass = CurrentScope.polymorphic_class(type, owner: self.class)
        next if klass.nil?
        # Fail closed on an un-introspectable key, as in RoleAssignment.
        next if begin
          CurrentScope.integer_keyed?(klass)
        rescue StandardError
          false
        end

        errors.add(:base, CurrentScope.non_integer_key_error(klass, role: role))
      end
    end
    private :polymorphic_keys_are_integer

    # Batch-load polymorphic resources for resolvable types only. A global
    # includes(:resource) NameErrors when any resource_type is stale; this
    # constantizes per type and skips unresolvable ones so they stay lazy
    # and orphaned_resource? labels them inert (#90 / PR #104 review).
    def self.preload_resolvable_resources!(assignments)
      list = Array(assignments)
      return list if list.empty?

      list.group_by(&:resource_type).each do |type, rows|
        next if type.blank?

        klass =
          begin
            type.constantize
          rescue NameError
            next
          end
        next unless klass.respond_to?(:where)

        records = klass.where(id: rows.map(&:resource_id).uniq).index_by { |r| r.id }
        rows.each do |row|
          assoc = row.association(:resource)
          assoc.target = records[row.resource_id]
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
