module CurrentScope
  class SubjectsController < ApplicationController
    # ponytail: unpaginated — paginate when subject counts make this page slow.
    def index
      @subjects = CurrentScope.config.subject_class.constantize.order(:id)
      @roles = Role.order(:name)
      @assignments = RoleAssignment.where(subject: @subjects)
                                   .index_by { |a| [ a.subject_type, a.subject_id ] }
      @scoped = ScopedRoleAssignment.where(subject: @subjects)
                                    .includes(:role, :resource)
                                    .group_by { |a| [ a.subject_type, a.subject_id ] }
    end
  end
end
