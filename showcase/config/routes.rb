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

  # The read-only "who can do what" roster (U13): visible to every acted-as
  # persona, unlike the full-access-gated engine UI. Excluded from the grid +
  # gate-skipped in the controller (a narrative surface, like the lobby).
  resources :users, only: :index

  mount CurrentScope::Engine => "/current_scope"
  resource :session
  resources :passwords, param: :token

  # The act-as switch: POST to step into a persona, DELETE to stop. Verb-pinned
  # (no GET) on purpose — a GET switch would be cross-site forceable.
  resource :act_as, only: %i[ create destroy ]

  # The guided fraud walkthrough (U12): a scripted "try to commit fraud →
  # refused" path. Gate-skipped + excluded from the grid (a narrative surface,
  # like the lobby), so the role-less Visitor can complete it. All GET — the
  # tour's state changes reuse the real POST endpoints (act-as, sign-in, approve).
  get "walkthrough(/:step)", to: "walkthrough#show", as: :walkthrough

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  root "home#index"
end
