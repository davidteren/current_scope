module CurrentScope
  module ApplicationHelper
    # Best-effort human label for any host subject/resource.
    def current_scope_label(record)
      name = record.try(:name) || record.try(:email) || record.try(:title)
      name || "#{record.class.name} ##{record.id}"
    end
  end
end
