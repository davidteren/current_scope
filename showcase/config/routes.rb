Rails.application.routes.draw do
  resources :reports do
    post :approve, on: :member
  end
  resources :projects
  mount CurrentScope::Engine => "/current_scope"
  resource :session
  resources :passwords, param: :token

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root "projects#index"
end
