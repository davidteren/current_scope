CurrentScope::Engine.routes.draw do
  root to: "roles#index"

  resources :roles
  resources :subjects, only: :index
  resource :role_assignment, only: :create
  resources :scoped_role_assignments, only: [ :new, :create, :destroy ]
end
