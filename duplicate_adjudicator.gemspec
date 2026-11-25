# frozen_string_literal: true

require_relative "lib/duplicate_adjudicator/version"

Gem::Specification.new do |spec|
  spec.name = "Duplicate Adjudicator"
  spec.version = DuplicateAdjudicator::VERSION
  spec.authors = ["Duplicate Adjudicator maintainers"]
  spec.summary = "Review matching file checksums in Manyfold"
  spec.description = "An administrator's queue for comparing duplicate files and recording review decisions."
  spec.metadata = {"manyfold_version" => "~> 0.154.4"}
end
