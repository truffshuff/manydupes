# frozen_string_literal: true

require "duplicate_adjudicator/version"
require "duplicate_adjudicator/index"
require "duplicate_adjudicator/verification"
require "duplicate_adjudicator/review_store"
require "duplicate_adjudicator/storage_preview"
require "duplicate_adjudicator/storage_operations"

module DuplicateAdjudicator
  class Engine < ::Rails::Engine
  end
end
