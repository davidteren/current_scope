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
      @subjects = subject_class.order(:id)
      # #183: the cascade picks the ROLE first, so the types are what gets
      # narrowed. A type that declares its grantable roles and does not list this
      # one is not offered, and the view says how many were withheld — silently
      # shortening a dropdown is its own kind of surprise. The model validation
      # is the actual gate; this only keeps the operator out of a dead end.
      @selected_role = Role.find_by(id: params[:role_id]) if params[:role_id].present?
      @all_scopeable = CurrentScope.scopeable_resources
      @scopeable = grantable_types(@all_scopeable, @selected_role)
      @bulk_subjects = resolve_bulk_subjects # [] unless a multi-select bulk grant

      # The record a deep link asked for, before any gate has judged it.
      linked = deep_linked_resource
      # Resolved against the FILTERED list: the cascade carries resource_type on
      # every autosubmit, so picking a role, then a type, then changing the role
      # would otherwise leave the withheld type selected, its records loaded and
      # a Grant button showing, directly under a hint saying that type was not
      # listed — the dead end this filter exists to prevent (#183 review).
      @resource_type = resolve_type(params[:resource_type], within: @scopeable) ||
                       deep_linked_type(linked)
      @resource, @refused_resource = judge_deep_link(linked, @resource_type)
      @searchable = searchable?(@resource_type)
      # Only an INDEXED scope looks past the scanned window. Without one, a
      # search re-reads the same rows the empty list came from, so telling the
      # operator to search would be advice that cannot work (#183 review).
      indexed_search = @resource_type.respond_to?(:current_scope_searchable_scope)
      @records, @records_withheld = candidate_records(@resource_type, params[:q], @selected_role)
      # ONE answer to "is there a search box on screen?", so the field and the
      # advice to use it cannot drift apart across the template (#183 review).
      @offer_search = @searchable && (@records.present? || indexed_search || params[:q].present?)
      # And whether searching is worth SUGGESTING: only an indexed scope reads
      # past the scanned window, so only then can a search reach a record the
      # role filter left out. Derived here so the box and the advice to use it
      # cannot drift apart across the template (#183 review).
      @advise_search = @records_withheld && @offer_search && indexed_search
      @grantable_gid = offered_gid(@resource, @records)
    end

    def create
      resource = GlobalID::Locator.locate(params.expect(:resource_gid))
      role = Role.find(params.expect(:role_id))
      subjects = locate_subjects(submitted_subject_gids)
      if subjects.empty?
        redirect_to subjects_path, alert: "No subjects selected."
        return
      end

      granted = 0
      # One transaction for the whole bulk grant — all-or-nothing, like the
      # org-wide sibling. A per-subject savepoint (grant_one) absorbs the
      # concurrent-duplicate race without poisoning the outer transaction, while
      # a genuine RecordInvalid rolls the entire batch back.
      ScopedRoleAssignment.transaction do
        subjects.each { |subject| granted += 1 if grant_one(subject, resource, role) }
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
      # Resolve the subject through the canonical guard, else fall back to the
      # assignment itself as the audit target — never the unrelated live record a
      # non-canonical stored id would cast into (#151). Mirrors cascade_subject.
      subject = assignment.current_scope_resolved_record("subject") || assignment
      role = assignment.role

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

    # A type with no declaration accepts everything, which is every host that
    # has not opted in.
    #
    # An STI base is always offered (#183 review): its table holds records of
    # several classes, the model gate judges the RECORD's own class, and a
    # type-level "no" here would make every Invoice unreachable in the console
    # because Document said no. The record list is what narrows instead.
    def grantable_types(types, role)
      return types if role.nil?

      types.select { |klass| grants_role?(klass, role) || sti_table?(klass) }
    end

    # No role chosen yet ⇒ nothing to filter by. THE one meaning of a nil role
    # in this controller: a call site that read it as "accepts nothing" broke
    # the documented deep link, which carries no role_id (#183 review).
    def grants_role?(klass, role)
      return true if role.nil?

      !klass.respond_to?(:current_scope_grants_role?) || klass.current_scope_grants_role?(role)
    end

    # True when a row queried through this class can load as a class OTHER than
    # this one — then the class the model gate will ask is not known until the
    # row itself is loaded, and the RECORD list is what narrows.
    #
    # Every class over a table with an inheritance column answers yes, leaves
    # included. Asking `subclasses` instead would be load-order dependent
    # (Zeitwerk loads on reference, and the dummy app does not eager-load in
    # test either), and the two ways of being wrong are not equal: offering a
    # leaf whose records all refuse costs one dropdown entry and an honest
    # empty message, while withholding a class whose subclass rows ARE
    # grantable hides those records with no way to reach them (#183 review).
    def sti_table?(klass)
      return false unless klass.respond_to?(:has_attribute?) && klass.respond_to?(:inheritance_column)

      klass.has_attribute?(klass.inheritance_column)
    rescue StandardError
      false # tableless double, or no database to ask
    end

    # The type for a deep link, only when the linked record's own class accepts
    # the chosen role.
    def deep_linked_type(linked)
      linked.class if linked && grants_role?(linked.class, @selected_role)
    end

    # → [ kept, refused ]. A deep-linked record survives only when it belongs to
    # the type on screen AND its own class accepts the chosen role. Without the
    # type half, a carried-over gid rides into a DIFFERENT type's record list as
    # the selected option; without the role half, a refused record keeps a Grant
    # button that only the model can then say no to. A refusal is REFUSED rather
    # than dropped, because a record that vanishes from the picker with no word
    # is the invisible dead end #183 exists to remove (#183 review).
    def judge_deep_link(linked, type)
      return [ nil, nil ] if linked.nil?
      return [ nil, linked ] unless grants_role?(linked.class, @selected_role)
      return [ nil, nil ] unless type && linked.is_a?(type)

      [ linked, nil ]
    end

    # The Grant button must post only a record the operator can SEE selected.
    # params[:resource_gid] survives every autosubmit, so changing the role or
    # the type can leave a gid from an earlier pick: the record select shows
    # nothing selected (it is not in the list) while the button would still post
    # it — a raw validation alert at best, and at worst a silent grant on a
    # record that is no longer on screen (#183 review).
    def offered_gid(resource, records)
      # The only source of a gid: a deep-linked resource is itself located from
      # this param, so there is no second one to fall back to.
      gid = params[:resource_gid].presence
      return nil if gid.blank? || @resource_type.nil?

      offered = Array(records).map { |record| record.to_gid.to_s }
      offered << resource.to_gid.to_s if resource # the view keeps it selectable
      gid if offered.include?(gid)
    end

    # The scoped record may be deleted (nil) or its class renamed (NameError) by
    # the time we revoke — label from the record when it's still there, else from
    # the stored type/id, so the audit event never 500s on a stale reference.
    def assignment_resource_label(assignment)
      resource = assignment.current_scope_resolved_record("resource")
      resource ? helpers.current_scope_label(resource) : "#{assignment.resource_type} ##{assignment.resource_id}"
    rescue StandardError
      # A host current_scope_label that raises must not 500 the revoke audit —
      # fall back to the stored type/id, matching cascade_resource_label.
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

    # Grant one scoped role inside its own savepoint. Returns true when a new
    # grant was recorded, false when the subject already had it (or a concurrent
    # grant won the race). A RecordInvalid propagates to roll the whole bulk back.
    def grant_one(subject, resource, role)
      ScopedRoleAssignment.transaction(requires_new: true) do
        assignment = ScopedRoleAssignment.find_or_create_by!(subject: subject, resource: resource, role: role)
        if assignment.previously_new_record?
          Event.record!(event: "scoped_role.granted", target: subject,
                        details: { role: role.name, resource: helpers.current_scope_label(resource) })
          true
        else
          false
        end
      end
    rescue ActiveRecord::RecordNotUnique
      false # a concurrent grant slipped past the validation to the DB index — already done
    rescue ActiveRecord::RecordInvalid => e
      # A concurrent grant of the same triple usually trips the uniqueness
      # VALIDATION first (RecordInvalid, not RecordNotUnique). Absorb only that
      # case per-subject; any other validation failure rolls the whole batch back.
      raise unless e.record.errors.of_kind?(:role_id, :taken)

      false
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
    def resolve_type(name, within:)
      within.find { |model| model.name == name } if name.present?
    end

    def searchable?(klass)
      klass.respond_to?(:count) && klass.count > SEARCH_THRESHOLD
    end

    # Returns [ records, withheld ]. `withheld` says the ROLE filter removed
    # rows, which is what lets the view explain an empty list instead of
    # blaming an empty table.
    def candidate_records(klass, query, role)
      return [ nil, false ] unless klass.respond_to?(:limit) # tableless / nil type ⇒ nothing to pick

      # A14: if the host model opts in with a class-level current_scope_searchable_scope,
      # search via that indexed relation — no SCAN_CAP, no in-Ruby label filter.
      if query.present? && klass.respond_to?(:current_scope_searchable_scope)
        # Only an STI table holds records with different answers, and there the
        # role filter has to run BEFORE the display cut or a grantable match
        # just past it disappears. Everywhere else one class decides for the
        # whole type, so the indexed scope keeps its promise of no SCAN_CAP.
        # The wider fetch buys nothing unless this hierarchy actually declares
        # its grantable roles: without an opt-in, every record is grantable and
        # the filter removes nothing. A host that adopted the indexed scope but
        # not #183 keeps the promise of no SCAN_CAP (#183 review).
        widen = role && sti_table?(klass) && klass.respond_to?(:current_scope_grants_role?)
        cap = widen ? SCAN_CAP : DISPLAY_LIMIT
        found = klass.current_scope_searchable_scope(query).limit(cap).to_a
        kept = grantable_records(found, role)
        return [ kept.first(DISPLAY_LIMIT), kept.size < found.size ]
      end

      # Fallback: current_scope_label is a Ruby method with no backing column, so
      # scan the first SCAN_CAP rows and filter the label in Ruby.
      records = klass.limit(SCAN_CAP).to_a
      if query.present?
        needle = query.downcase
        records = records.select { |record| helpers.current_scope_label(record).downcase.include?(needle) }
      end
      kept = grantable_records(records, role)
      [ kept.first(DISPLAY_LIMIT), kept.size < records.size ]
    end

    # The model gate judges the record's OWN class, so an STI table can hold
    # records that accept the role beside records that do not.
    def grantable_records(records, role)
      return records if role.nil?

      records.select { |record| grants_role?(record.class, role) }
    end
  end
end
