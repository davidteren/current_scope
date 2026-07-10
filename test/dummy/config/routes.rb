Rails.application.routes.draw do
  resources :reports, only: [ :index, :show, :destroy ] do
    post :approve, on: :member
  end

  mount CurrentScope::Engine => "/current_scope"
end
