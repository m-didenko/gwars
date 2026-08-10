Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  devise_for :users
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  resource :character, only: [:new, :create, :show]

  get "lobby", to: "lobby#show", as: :lobby
  post "lobby/join", to: "lobby#join", as: :join_lobby
  post "lobby/leave", to: "lobby#leave", as: :leave_lobby

  resources :battles, only: [:index, :new, :create, :show] do
    member do
      get :state
      get :log
      post :accept, to: "battle_turns#accept"
      post :aim, to: "battle_turns#aim"
      post :move, to: "battle_turns#move"
      post :expire, to: "battle_turns#expire"
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  root "lobby#show"
end
