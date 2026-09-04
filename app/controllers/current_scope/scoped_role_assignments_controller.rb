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
      # scalar_param: a nested query string (?role_id[x]=1) is not an id, and
      # every reader below expects a string. Rails answers nil for it today
      # rather than raising, so this states the expectation rather than fixing a
      # live break (#183).
      @selected_role = Role.find_by(id: scalar_param(:role_id)) if params[:role_id].present?
      # A deleted role in a stale bookmark reads as "no role chosen" everywhere
      # downstream, which would show every type and every record with no hint
      # and a Grant button that can only fail on POST (#183).
      @missing_role = scalar_param(:role_id).present? && @selected_role.nil?
      # Read once, through the same guard as every other param the picker takes.
      @query = scalar_param(:q)
      @subject_gid = scalar_param(:subject_gid)
      all_scopeable = CurrentScope.scopeable_resources
      # #183: the cascade picks the ROLE first, so the types are what gets
      # narrowed. A type that declares its grantable roles and does not list this
      # one is not offered, and the view says how many were withheld — silently
      # shortening a dropdown is its own kind of surprise. The model validation
      # is the actual gate; this only keeps the operator out of a dead end.
      scopeable = grantable_types(all_scopeable, @selected_role)
      @bulk_subjects = resolve_bulk_subjects # [] unless a multi-select bulk grant

      # One answer to "what did the link and the type dropdown resolve to?",
      # judged once, so the four values that must agree cannot be threaded
      # through this action in the wrong order (#183).
      link = resolve_deep_link(scopeable)
      @resource_type = link.type
      @types = PickerTypeStep.new(all_types: all_scopeable, offered: scopeable,
                                  resolved: link.type, role: @selected_role,
                                  anchor: link.anchor, refused_link: link.refused)
      records, withheld, unread = candidate_records(@resource_type, @query, @selected_role)
      # One object owns every display decision for the record step, so the
      # control and the sentence beside it cannot drift apart (#183).
      @step = PickerRecordStep.new(
        records: records, withheld: withheld, unread: unread,
        # Only an INDEXED scope looks past the scanned window; without one a
        # search re-reads the very rows an empty list came from.
        indexed: @resource_type.respond_to?(:current_scope_searchable_scope),
        searchable: searchable?(@resource_type), query: @query,
        selected: link.record,
        # An empty declaration on the chosen type is a LOCKDOWN: no role will
        # ever list a record that inherits it, so "pick a different role" is a
        # promise none can keep. The type step says this for a type it withheld;
        # an STI base is kept ON OFFER, so the record step has to say it too
        # (#183).
        locked: @resource_type.try(:current_scope_locked_down_everywhere?) || false
      )
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
    # An STI base is always offered (#183): its table holds records of
    # several classes, the model gate judges the RECORD's own class, and a
    # type-level "no" here would make every Invoice unreachable in the console
    # because Document said no. The record list is what narrows instead.
    def grantable_types(types, role)
      return types if role.nil?

      types.select { |klass| filter_allows?(klass, role) || sti_table?(klass) }
    end

    # Deliberately NOT named grants_role?: the public
    # CurrentScope::GrantableRoles.current_scope_grants_role? answers FALSE for a
    # nil role (nothing can be granted for a role that is not there), while the
    # filter's question is "does this survive the role the operator picked?",
    # which nothing narrows when no role is picked. Two near-identical names
    # with opposite nil answers is how the documented deep link broke once
    # already in this branch (#183).
    def filter_allows?(klass, role)
      return true if role.nil?

      !klass.respond_to?(:current_scope_grants_role?) || klass.current_scope_grants_role?(role)
    end

    # True when a row queried through this class can load as a class OTHER than
    # this one — then the class the model gate will ask is not known until the
    # row is loaded, and the RECORD list is what narrows. Every class over a
    # table with an inheritance column answers yes, leaves included, and so does
    # a plain model that happens to use `type` for its own purposes: offering it
    # costs one dropdown entry and an honest empty message, while withholding a
    # class whose subclass rows ARE grantable would hide them with no way back.
    #
    # The `try` covers a deep-linked class that includes neither the module nor
    # ActiveRecord.
    def sti_table?(klass)
      klass.try(:current_scope_inheritable_table?) || false
    end

    # The type for a deep link, only when the linked record's own class accepts
    # the chosen role.
    def deep_linked_type(linked, role)
      linked.class if linked && filter_allows?(linked.class, role)
    end

    # The record the form may act on. It survives only when it belongs to
    # the type on screen AND its own class accepts the chosen role. Without the
    # type half, a carried-over gid rides into a DIFFERENT type's record list as
    # the selected option; without the role half, a refused record keeps a Grant
    # button that only the model can then say no to. A refusal is REFUSED rather
    # than dropped, because a record that vanishes from the picker with no word
    # is the invisible dead end #183 exists to remove (#183).
    def kept_deep_link(linked, type, role, chosen_type)
      return nil if linked.nil?
      # The operator moved to another type: the carried gid is not a link they
      # followed (#183).
      return nil if chosen_type && !linked.is_a?(chosen_type)
      return nil unless filter_allows?(linked.class, role)
      return nil unless type && linked.is_a?(type)

      linked
    end

    # The linked record the chosen role may not be granted on. Silent once the
    # operator has moved to another type, for the same reason: it is then not a
    # link they followed.
    def refused_deep_link(anchor, role, chosen_type)
      return nil if anchor.nil?
      return nil if chosen_type && !anchor.is_a?(chosen_type)

      anchor unless filter_allows?(anchor.class, role)
    end

    # Every param this picker reads is a string: an id, a GlobalID, a type name,
    # a search term. A nested or array param is none of those, so it is read as
    # absent and the page renders the state it has for "not found" (#183).
    def scalar_param(name)
      value = params[name]
      value if value.is_a?(String)
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
    def deep_linked_resource(gid)
      GlobalID::Locator.locate(gid) if gid.present?
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

    # What the deep link and the type dropdown resolve to: the type on screen,
    # the record the Grant button may post, the refusal to explain, and the
    # anchor the cascade carries so an unregistered linked type survives the
    # record being cleared.
    DeepLink = Struct.new(:type, :record, :refused, :anchor)
    private_constant :DeepLink

    def resolve_deep_link(scopeable)
      # The record a deep link asked for, before any gate has judged it, and the
      # anchor that outlives it: blanking the Record select would otherwise drop
      # an unregistered deep-linked type out of the picker.
      linked = deep_linked_resource(scalar_param(:resource_gid))
      anchor = linked || deep_linked_resource(scalar_param(:linked_gid))
      # Resolved against the FILTERED list: the cascade carries resource_type on
      # every autosubmit, so picking a role, then a type, then changing the role
      # would otherwise leave the withheld type selected, its records loaded and
      # a Grant button showing, directly under a hint saying that type was not
      # listed — the dead end this filter exists to prevent (#183).
      chosen = resolve_type(scalar_param(:resource_type), within: scopeable)
      type = chosen || deep_linked_type(anchor, @selected_role)
      DeepLink.new(type,
                   kept_deep_link(linked, type, @selected_role, chosen),
                   # From the ANCHOR, not the selected record: on the submits
                   # where the record select is not on screen only linked_gid
                   # comes back, and the explanation would vanish exactly where
                   # the operator is stuck (#183).
                   refused_deep_link(anchor, @selected_role, chosen),
                   anchor)
    end

    # Only registered Scopeable types are resolvable from params — never
    # constantize arbitrary visitor input.
    def resolve_type(name, within:)
      within.find { |model| model.name == name } if name.present?
    end

    def searchable?(klass)
      klass.respond_to?(:count) && klass.count > SEARCH_THRESHOLD
    end

    # Returns [ records, withheld, unread ]. `withheld` says the ROLE filter
    # removed rows, which is what lets the view explain an empty list instead of
    # blaming an empty table. `unread` says the scan stopped at its cap, so
    # records exist that nothing here has looked at — the only state where
    # searching can turn up something new.
    def candidate_records(klass, query, role)
      return [ nil, false, false ] unless klass.respond_to?(:limit) # tableless / nil type ⇒ nothing to pick

      # A14: if the host model opts in with a class-level current_scope_searchable_scope,
      # search via that indexed relation — no SCAN_CAP, no in-Ruby label filter.
      if query.present? && klass.respond_to?(:current_scope_searchable_scope)
        # Only an STI table holds records with different answers, and there the
        # role filter has to run BEFORE the display cut or a grantable match
        # just past it disappears. Everywhere else one class decides for the
        # whole type, so the indexed scope keeps its promise of no SCAN_CAP.
        #
        # And only where a declaration can actually remove rows. Without one
        # the filter keeps everything, so widening would instantiate 450 extra
        # records per keystroke for a host that never opted into #183 — the very
        # cost the indexed scope exists to avoid (#183).
        #
        # `declares_roles_anywhere?` reads `descendants`, which sees only LOADED
        # classes. Eager loading makes that usually complete in production, not
        # guaranteed — `do_not_eager_load` and models outside the eager-load
        # paths still miss it — and development is pessimistic outright: a
        # declaring subclass nobody has referenced
        # yet reads as "no declaration", the fetch stays at 50, and a grantable
        # record past row 50 is not offered until something loads that class.
        # Browse-only, and it self-corrects on the next request that touches the
        # subclass, so it is not worth 450 rows a keystroke in production.
        cap = role && sti_table?(klass) && klass.try(:current_scope_declares_roles_anywhere?) ? SCAN_CAP : DISPLAY_LIMIT
        # One row PAST the cap, and dropped again: a table holding exactly `cap`
        # rows was read to the end, and calling that "more to find" would offer
        # a search that cannot reach anything (#183).
        fetched = klass.current_scope_searchable_scope(query).limit(cap + 1).to_a
        found = fetched.first(cap)
        kept = grantable_records(found, role)
        return [ kept.first(DISPLAY_LIMIT), kept.size < found.size, fetched.size > cap ]
      end

      # Fallback: current_scope_label is a Ruby method with no backing column, so
      # scan the first SCAN_CAP rows and filter the label in Ruby.
      fetched = klass.limit(SCAN_CAP + 1).to_a # one past the cap: see above
      scanned = fetched.first(SCAN_CAP)
      records = scanned
      if query.present?
        needle = query.downcase
        records = records.select { |record| helpers.current_scope_label(record).downcase.include?(needle) }
      end
      kept = grantable_records(records, role)
      [ kept.first(DISPLAY_LIMIT), kept.size < records.size, fetched.size > SCAN_CAP ]
    end

    # The model gate judges the record's OWN class, so an STI table can hold
    # records that accept the role beside records that do not.
    def grantable_records(records, role)
      return records if role.nil?

      records.select { |record| filter_allows?(record.class, role) }
    end
  end
end
