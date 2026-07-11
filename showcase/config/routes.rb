Rails.application.routes.draw do
  resources :reports do
    post :approve, on: :member
  end
  # The three SoD gallery domains — same shape as reports.
  resources :pay_runs do
    post :approve, on: :member
  end
  resources :contracts do
    post :approve, on: :member
  end
  resources :expense_claims do
    post :approve, on: :member
  end
  resources :projects
  mount CurrentScope::Engine => "/current_scope"
  resource :session
  resources :passwords, param: :token

  # The act-as switch: POST to step into a persona, DELETE to stop. Verb-pinned
  # (no GET) on purpose — a GET switch would be cross-site forceable.
  resource :act_as, only: %i[ create destroy ]

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root "home#index"
end
