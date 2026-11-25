# frozen_string_literal: true

require "duplicate_adjudicator/version"
require "duplicate_adjudicator/index"
require "duplicate_adjudicator/verification"
require "duplicate_adjudicator/storage_preview"

module DuplicateAdjudicator
  class Engine < ::Rails::Engine
  end
end
