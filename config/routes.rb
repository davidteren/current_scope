CurrentScope::Engine.routes.draw do
  root to: "roles#index"

  resources :roles, except: :show do
    member { get :members }
  end
  resources :subjects, only: :index
  resources :events, only: :index
  resource :role_assignment, only: :create
  # Remove one org-wide assignment by id (members page: clean up an orphan whose
  # subject was deleted, which the subject-keyed clear on create can't target).
  delete "role_assignments/:id" => "role_assignments#destroy", as: :remove_role_assignment
  resources :scoped_role_assignments, only: [ :new, :create, :destroy ]
end
