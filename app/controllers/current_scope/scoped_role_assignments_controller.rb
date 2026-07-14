module CurrentScope
  # Grants/revokes a role on ONE specific record. `new` is a guided cascade
  # (Role → Subject → Resource type → Record); `create` grants; `destroy`
  # revokes. A record page can still deep-link straight to a target with:
  #
  #   current_scope.new_scoped_role_assignment_path(resource_gid: record.to_gid)
  class ScopedRoleAssignmentsController < ApplicationController
    # ponytail: record search scans only the first SCAN_CAP rows of a type and
    # renders at most DISPLAY_LIMIT matches. current_scope_label is a Ruby
    # method with no backing column, so the filter runs in Ruby (not SQL LIKE);
    # a dedicated indexed label column is the upgrade path for large tables.
    SCAN_CAP = 500
    DISPLAY_LIMIT = 50
    # Offer a search box (instead of listing every record) past this many.
    SEARCH_THRESHOLD = 20

    def new
      @assignment = ScopedRoleAssignment.new
      @roles = Role.order(:name)
      @subjects = CurrentScope.config.subject_class.constantize.order(:id)
      @scopeable = CurrentScope.scopeable_resources
      @bulk_subjects = resolve_bulk_subjects # [] unless a multi-select bulk grant

      @resource = deep_linked_resource
      @resource_type = resolve_type(params[:resource_type]) || @resource&.class
      @searchable = searchable?(@resource_type)
      @records = candidate_records(@resource_type, params[:q])
    end

    def create
      resource = GlobalID::Locator.locate(params.expect(:resource_gid))
      role = Role.find(params.expect(:role_id))
      subjects = grant_subjects
      if subjects.empty?
        redirect_to subjects_path, alert: "No subjects selected."
        return
      end
      granted = 0

      subjects.each do |subject|
        ScopedRoleAssignment.transaction do
          assignment = ScopedRoleAssignment.find_or_create_by!(subject: subject, resource: resource, role: role)
          next unless assignment.previously_new_record?

          Event.record!(event: "scoped_role.granted", target: subject,
                        details: { role: role.name, resource: helpers.current_scope_label(resource) })
          granted += 1
        end
      rescue ActiveRecord::RecordNotUnique
        next # a concurrent grant of the same triple — treat as already done
      end

      redirect_to subjects_path, notice: grant_notice(granted, subjects.size)
    rescue ActiveRecord::RecordInvalid => e
      redirect_to subjects_path, alert: e.message
    rescue ActiveRecord::RecordNotFound, NameError
      redirect_to subjects_path,
                  alert: "Couldn't grant that scoped role — the subject, role, or record is no longer available."
    end

    def destroy
      assignment = ScopedRoleAssignment.find(params[:id])
      subject, role = assignment.subject, assignment.role

      ScopedRoleAssignment.transaction do
        assignment.destroy!
        Event.record!(event: "scoped_role.revoked", target: subject,
                      details: { role: role.name, resource: assignment_resource_label(assignment) })
      end
      redirect_to subjects_path, notice: "Scoped role revoked."
    rescue ActiveRecord::RecordNotFound
      redirect_to subjects_path, notice: "That scoped role was already revoked."
    end

    private

    # The scoped record may be deleted (nil) or its class renamed (NameError) by
    # the time we revoke — label from the record when it's still there, else from
    # the stored type/id, so the audit event never 500s on a stale reference.
    def assignment_resource_label(assignment)
      resource = assignment.resource
      resource ? helpers.current_scope_label(resource) : "#{assignment.resource_type} ##{assignment.resource_id}"
    rescue NameError, ActiveRecord::RecordNotFound
      "#{assignment.resource_type} ##{assignment.resource_id}"
    end

    # Deep-link prefill: a record page links here with resource_gid. A stale
    # link (deleted record → RecordNotFound, renamed class → NameError) must
    # not 500 — fall back to the blank picker with a friendly alert.
    def deep_linked_resource
      GlobalID::Locator.locate(params[:resource_gid]) if params[:resource_gid].present?
    rescue ActiveRecord::RecordNotFound, NameError
      flash.now[:alert] = "That linked record is no longer available — pick one below."
      nil
    end

    # The subjects to grant to: the multi-select bulk set when present, else the
    # single cascade subject.
    def grant_subjects
      gids = Array(params[:subject_gids]).select(&:present?)
      gids = [ params[:subject_gid] ].compact if gids.empty?
      locate_subjects(gids)
    end

    # Resolve the bulk subject_gids for display (dead links and non-subject GIDs
    # drop out — same boundary the grant enforces).
    def resolve_bulk_subjects
      locate_subjects(params[:subject_gids])
    end

    def grant_notice(granted, attempted)
      return "Those subjects already have that scoped role." if granted.zero?
      return "Scoped role granted." if granted == 1 && attempted == 1

      "Scoped role granted to #{granted} #{'subject'.pluralize(granted)}."
    end

    # Only registered Scopeable types are resolvable from params — never
    # constantize arbitrary visitor input.
    def resolve_type(name)
      CurrentScope.scopeable_resources.find { |model| model.name == name } if name.present?
    end

    def searchable?(klass)
      klass.respond_to?(:count) && klass.count > SEARCH_THRESHOLD
    end

    def candidate_records(klass, query)
      return unless klass.respond_to?(:limit) # tableless / nil type ⇒ nothing to pick

      # A14: if the host model opts in with a class-level current_scope_searchable_scope,
      # search via that indexed relation — no SCAN_CAP, no in-Ruby label filter.
      if query.present? && klass.respond_to?(:current_scope_searchable_scope)
        return klass.current_scope_searchable_scope(query).limit(DISPLAY_LIMIT).to_a
      end

      # Fallback: current_scope_label is a Ruby method with no backing column, so
      # scan the first SCAN_CAP rows and filter the label in Ruby.
      records = klass.limit(SCAN_CAP).to_a
      if query.present?
        needle = query.downcase
        records = records.select { |record| helpers.current_scope_label(record).downcase.include?(needle) }
      end
      records.first(DISPLAY_LIMIT)
    end
  end
end
