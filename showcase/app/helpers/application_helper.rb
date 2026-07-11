module ApplicationHelper
  # The sandbox self-heals on a */15 schedule (config/recurring.yml). Cheap,
  # honest estimate of minutes to the next quarter-hour boundary — no scheduler
  # lookup, just the wall clock the cron fires against.
  def minutes_to_next_sandbox_reset
    15 - (Time.current.min % 15)
  end

  # Label a scoped role's target record. A scoped role can point at ANY model
  # (the engine's raw-GlobalID contract), not only CurrentScope::Scopeable ones,
  # so this is defensive: use the record's own current_scope_label when it has
  # one, otherwise "Type #id", and never raise on a missing method or a dead /
  # renamed resource reference (`&.` guards nil, not an absent method).
  def scoped_resource_label(assignment)
    resource = assignment.resource
    if resource.respond_to?(:current_scope_label)
      resource.current_scope_label
    else
      "#{assignment.resource_type} ##{assignment.resource_id}"
    end
  rescue NameError, ActiveRecord::RecordNotFound
    "#{assignment.resource_type} ##{assignment.resource_id}"
  end
end
