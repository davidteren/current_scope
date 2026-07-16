Rails.application.routes.draw do
  resources :reports, only: [ :index, :show, :destroy ] do
    post :approve, on: :member
  end

  # A full RESTful resource so the permission grid has every CRUD column.
  # DocumentsController is an STI base (Document/Invoice) declaring
  # current_scope_model, so the record-less type bind (#50) has a request-level
  # STI reproduction.
  resources :documents

  # A routed path with DELIBERATELY no controller class — the
  # ActionDispatch::MissingController shape GatingReflection (#62) must treat as
  # unprovable. Kept dedicated so #50's real DocumentsController and #62's
  # classless case cannot collide (plan 030 U4's own coupling note).
  resources :orphaned, only: :index

  # A NAMESPACED SoD controller: path "admin/reports", records are Reports.
  namespace :admin do
    resources :reports, only: [] do
      post :approve, on: :member
    end
  end

  resources :webhooks, only: :create
  get "bare", to: "bare#show"
  get "identity", to: "identity#show"
  get "tripwire_open", to: "tripwire_ungated#open"
  get "tripwire_public", to: "tripwire_ungated#public_action"
  get "tripwire_gated", to: "tripwire_gated#show"
  post "sod_nil/approve", to: "sod_nil#approve"
  # A member route whose controller declares no current_scope_record hook.
  resources :hookless_member, only: :show
  # Same, but with custom member params — neither may read as a collection.
  resources :slug_reports, only: :show, param: :slug
  resources :external_id_reports, only: :show, param: :external_id
  # A nested COLLECTION — its only dynamic segment is the parent's :project_id,
  # so it must still read as a collection and stay reachable.
  # projects routes its own collection actions (#50: the escalation repro —
  # a Report-scoped subject probing projects#index/#create) AND nests
  # nested_reports.
  resources :projects, only: [ :index, :create ] do
    resources :nested_reports, only: :index
  end
  # #50 U3 diagnostics shapes: a declared-nil collection with NO
  # current_scope_model (the :model_undeclared deny + nudge), and a declared
  # model with NO record hook (the R9 inert-model clause).
  get "undeclared_model", to: "undeclared_model#index"
  get "inert_model", to: "inert_model#index"
  post "writes/guarded", to: "writes#guarded", as: :writes_guarded
  post "writes/unguarded", to: "writes#unguarded", as: :writes_unguarded

  # The #62 fail-open shapes: a routed base with a bare skip, the child that
  # inherits it silently, the child that re-asserts the gate, and a
  # conditional skip (index ungated, show still gated).
  get "inherited_skip_base", to: "inherited_skip_base#index"
  get "inherited_skip_child", to: "inherited_skip_child#index"
  get "reasserted_gate", to: "reasserted_gate#index"
  get "conditional_skip", to: "conditional_skip#index"
  get "conditional_skip/show", to: "conditional_skip#show"
  # The same conditional-skip shape with the tripwire included (U5).
  get "conditional_skip_tripwire", to: "conditional_skip_tripwire#index"
  get "conditional_skip_tripwire/show", to: "conditional_skip_tripwire#show"
  # A NAMESPACED ungated controller — the badge id/aria path for "admin/…".
  get "admin/unguarded", to: "admin/unguarded#index"

  mount CurrentScope::Engine => "/current_scope"
end
