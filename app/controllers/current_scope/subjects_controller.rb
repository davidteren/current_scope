module CurrentScope
  class SubjectsController < ApplicationController
    PER_PAGE = 50

    def index
      scope = CurrentScope.config.subject_class.constantize.order(:id)
      @page = [ params[:page].to_i, 1 ].max
      @subjects = scope.limit(PER_PAGE).offset((@page - 1) * PER_PAGE)
      @has_next_page = scope.offset(@page * PER_PAGE).exists?

      @roles = Role.order(:name)
      @assignments = RoleAssignment.where(subject: @subjects)
                                   .index_by { |a| [ a.subject_type, a.subject_id ] }
      @scoped = ScopedRoleAssignment.where(subject: @subjects)
                                    .includes(:role, :resource)
                                    .group_by { |a| [ a.subject_type, a.subject_id ] }
    end
  end
end
