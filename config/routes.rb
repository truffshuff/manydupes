# frozen_string_literal: true

DuplicateAdjudicator::Engine.routes.draw do
  root to: "duplicate_adjudicator/reviews#index"
  get "theme.css", to: "duplicate_adjudicator/reviews#theme", defaults: {format: :css}, format: false
  get "review.js", to: "duplicate_adjudicator/reviews#script", defaults: {format: :js}, format: false
  get "group/:digest", to: "duplicate_adjudicator/reviews#show", as: :group
  post "group/:digest/verify", to: "duplicate_adjudicator/reviews#verify", as: :verify
end
