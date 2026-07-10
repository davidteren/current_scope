module CurrentScope
  class SubjectsController < ApplicationController
    def index
      @subjects = CurrentScope.config.subject_class.constantize.order(:id)
      @roles = Role.order(:name)
    end
  end
end
