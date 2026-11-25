# frozen_string_literal: true

DuplicateAdjudicator::Engine.routes.draw do
  root to: "duplicate_adjudicator/reviews#index"
  get "theme.css", to: "duplicate_adjudicator/reviews#theme", defaults: {format: :css}, format: false
  get "review.js", to: "duplicate_adjudicator/reviews#script", defaults: {format: :js}, format: false
  get "group/:digest", to: "duplicate_adjudicator/reviews#show", as: :group
  post "group/:digest/verify", to: "duplicate_adjudicator/reviews#verify", as: :verify
  post "group/:digest/storage", to: "duplicate_adjudicator/reviews#storage", as: :storage
  post "group/:digest/link", to: "duplicate_adjudicator/reviews#link_copies"
  get "backups", to: "duplicate_adjudicator/reviews#backups"
  post "backups/:id/restore", to: "duplicate_adjudicator/reviews#restore_copy"
  post "backups/:id/purge", to: "duplicate_adjudicator/reviews#purge_backup"
  post "group/:digest/warnings", to: "duplicate_adjudicator/reviews#warnings", as: :warnings
end
