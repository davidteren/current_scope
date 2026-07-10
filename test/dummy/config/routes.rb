Rails.application.routes.draw do
  resources :reports, only: [ :index, :show, :destroy ] do
    post :approve, on: :member
  end

  resources :webhooks, only: :create
  get "bare", to: "bare#show"
  get "identity", to: "identity#show"
  post "writes/guarded", to: "writes#guarded", as: :writes_guarded
  post "writes/unguarded", to: "writes#unguarded", as: :writes_unguarded

  mount CurrentScope::Engine => "/current_scope"
end
