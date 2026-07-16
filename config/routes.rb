CurrentScope::Engine.routes.draw do
  root to: "roles#index"

  resources :roles, except: :show do
    member { get :members }
  end
  resources :subjects, only: :index
  resources :events, only: :index
  # create is subject-keyed (no id); destroy removes one assignment by id (the
  # members page's cleanup path for an orphan whose subject was deleted).
  resources :role_assignments, only: [ :create, :destroy ]
  resources :scoped_role_assignments, only: [ :new, :create, :destroy ]
end
