# frozen_string_literal: true

DuplicateAdjudicator::Engine.routes.draw do
  root to: "duplicate_adjudicator/reviews#index"
  get "theme.css", to: "duplicate_adjudicator/reviews#theme", defaults: {format: :css}, format: false
  get "review.js", to: "duplicate_adjudicator/reviews#script", defaults: {format: :js}, format: false
  get "group/:digest", to: "duplicate_adjudicator/reviews#show", as: :group
  post "page-links/plan", to: "duplicate_adjudicator/reviews#page_link_plan"
  post "page-links/apply", to: "duplicate_adjudicator/reviews#apply_page_links"
  post "page-links/acknowledge", to: "duplicate_adjudicator/reviews#acknowledge_page_warnings"
  post "queue-links", to: "duplicate_adjudicator/reviews#queue_links"
  post "review-import", to: "duplicate_adjudicator/reviews#import_reviews"
  post "group/:digest/decision", to: "duplicate_adjudicator/reviews#decision"
  post "group/:digest/verify", to: "duplicate_adjudicator/reviews#verify", as: :verify
  post "group/:digest/storage", to: "duplicate_adjudicator/reviews#storage", as: :storage
  post "group/:digest/independent", to: "duplicate_adjudicator/reviews#independent"
  post "group/:digest/make-independent", to: "duplicate_adjudicator/reviews#make_independent"
  post "group/:digest/link", to: "duplicate_adjudicator/reviews#link_copies"
  get "backups", to: "duplicate_adjudicator/reviews#backups"
  post "backups/:id/restore", to: "duplicate_adjudicator/reviews#restore_copy"
  post "backups/:id/purge", to: "duplicate_adjudicator/reviews#purge_backup"
  post "group/:digest/warnings", to: "duplicate_adjudicator/reviews#warnings", as: :warnings
end
