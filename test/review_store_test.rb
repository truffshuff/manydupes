# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/duplicate_adjudicator/index"
require_relative "../lib/duplicate_adjudicator/review_store"

class ReviewStoreTest < Minitest::Test
  def test_updates_survive_a_new_session_and_are_account_scoped
    Dir.mktmpdir do |directory|
      data = File.join(directory, "reviews")
      digest = "f" * 128
      first = DuplicateAdjudicator::ReviewStore.new(data, 50)
      first.update(digest, "snapshot") { |state| state["decision"] = {"type" => "keep"} }
      second = DuplicateAdjudicator::ReviewStore.new(data, 50)
      fourth = DuplicateAdjudicator::ReviewStore.new(data, 51)
      assert_equal({"type" => "keep"}, second.read(digest)["decision"])
      assert_nil fourth.read(digest)
      second.update(digest, "snapshot") { |state| state["copies"] |= ["one-copy"] }
      second.update(digest, "snapshot", import: true) { flunk "An import overwrote a newer decision" }
      assert_equal ["one-copy"], first.read(digest)["copies"]
      assert_equal({"type" => "keep"}, first.read(digest)["decision"])
      second.update(digest, "changed-snapshot") { |state| state["decision"] = nil }
      assert_empty first.read(digest)["copies"]
      assert_nil first.read(digest)["decision"]
    end
  end
end
