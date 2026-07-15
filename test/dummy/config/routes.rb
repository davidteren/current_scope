Rails.application.routes.draw do
  resources :reports, only: [ :index, :show, :destroy ] do
    post :approve, on: :member
  end

  # A full RESTful resource so the permission grid has every CRUD column.
  resources :documents

  resources :webhooks, only: :create
  get "bare", to: "bare#show"
  get "identity", to: "identity#show"
  get "tripwire_open", to: "tripwire_ungated#open"
  get "tripwire_public", to: "tripwire_ungated#public_action"
  get "tripwire_gated", to: "tripwire_gated#show"
  post "sod_nil/approve", to: "sod_nil#approve"
  # A member route whose controller declares no current_scope_record hook.
  resources :hookless_member, only: :show
  post "writes/guarded", to: "writes#guarded", as: :writes_guarded
  post "writes/unguarded", to: "writes#unguarded", as: :writes_unguarded

  mount CurrentScope::Engine => "/current_scope"
end
