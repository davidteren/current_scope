module CurrentScope
  class RolesController < ApplicationController
    def index
      @roles = Role.order(:name)
    end

    def new
      @role = Role.new
    end

    def create
      @role = Role.new(role_params)
      if @role.save
        redirect_to edit_role_path(@role), notice: "Role created."
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      @role = Role.find(params[:id])
    end

    def update
      @role = Role.find(params[:id])
      if @role.update(role_params)
        redirect_to roles_path, notice: "Role updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy
      Role.find(params[:id]).destroy!
      redirect_to roles_path, notice: "Role deleted."
    end

    private

    def role_params
      params.expect(role: [ :name, :full_access, permission_keys: [] ])
    end
  end
end
