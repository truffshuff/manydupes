# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "../lib/duplicate_adjudicator/index"
require_relative "../lib/duplicate_adjudicator/storage_preview"
require_relative "../lib/duplicate_adjudicator/storage_operations"

class StorageOperationsTest < Minitest::Test
  Library = Struct.new(:path, :storage_service)
  Model = Struct.new(:library)
  Copy = Struct.new(:model, :path_within_library, :size, :public_id)

  def setup
    @temporary = Dir.mktmpdir("duplicate-adjudicator-operations")
    @mount = Pathname.new(@temporary).realpath
    @root = @mount.join("duplicates")
    @left_path = @mount.join("Library A", "Sets", "Keeper.stl")
    @right_path = @mount.join("Library B", "Parts", "Duplicate.stl")
    [@left_path, @right_path].each do |path|
      FileUtils.mkdir_p(path.dirname)
      File.write(path, "same bytes")
    end
    @digest = Digest::SHA512.hexdigest("same bytes")
    @library_a = Library.new(@mount.join("Library A").to_s, "filesystem")
    @library_b = Library.new(@mount.join("Library B").to_s, "filesystem")
    @left = Copy.new(Model.new(@library_a), "Sets/Keeper.stl", 10, "left")
    @right = Copy.new(Model.new(@library_b), "Parts/Duplicate.stl", 10, "right")
    @store = DuplicateAdjudicator::StorageOperations.new([@library_a, @library_b], root: @root.to_s)
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def test_preview_is_read_only_and_restore_preserves_the_original
    original_inode = @right_path.stat.ino
    plan = @store.plan(@left, @right)
    assert_equal "Library B/Parts/Duplicate.stl", plan.target
    refute @root.exist?

    id = apply(plan)
    backup = saved_original(id)
    assert_equal @left_path.stat.ino, @right_path.stat.ino
    assert_equal original_inode, backup.stat.ino
    assert_equal [42], @store.read(id)["warnings"]
    assert_equal "linked", @store.state(@store.read(id))

    @store.finish(id, @right, :restore)
    assert_equal original_inode, @right_path.stat.ino
    refute_equal @left_path.stat.ino, @right_path.stat.ino
    refute backup.exist?
    assert_equal "restored", @store.state(@store.read(id))
  end

  def test_purge_removes_only_the_saved_original_and_can_be_retried
    id = apply
    @store.finish(id, @right, :purge)
    refute saved_original(id).exist?
    assert_equal @left_path.stat.ino, @right_path.stat.ino
    assert_equal "same bytes", @right_path.read
    assert_equal "purged", @store.finish(id, @right, :purge)["state"]
  end

  def test_stale_or_wrong_bytes_leave_both_paths_independent
    plan = @store.plan(@left, @right)
    @right_path.write("new  bytes")
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) { apply(plan) }
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) { apply }
    assert_empty @store.batches
    refute_equal @left_path.stat.ino, @right_path.stat.ino
    assert_equal "new  bytes", @right_path.read
  end

  def test_edits_after_linking_block_purge_and_restore
    id = apply
    @right_path.write("new  bytes")
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) { @store.finish(id, @right, :purge) }
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) { @store.finish(id, @right, :restore) }
    assert_equal "same bytes", saved_original(id).read
    assert_equal "new  bytes", @right_path.read
  end

  def test_restore_refuses_a_stale_manyfold_path
    id = apply
    @right.path_within_library = "Parts/Moved.stl"
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) { @store.finish(id, @right, :restore) }
    assert saved_original(id).exist?
  end

  def test_archive_cannot_overlap_any_library
    overlapping_library = Library.new(@mount.to_s, "filesystem")
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) do
      DuplicateAdjudicator::StorageOperations.new([@library_a, overlapping_library], root: @root.to_s)
    end
  end

  def test_link_failure_leaves_the_original_and_a_recoverable_backup
    failing_store = Class.new(DuplicateAdjudicator::StorageOperations) do
      private

      def replace_with_link(...)
        raise Errno::EXDEV
      end
    end.new([@library_a, @library_b], root: @root.to_s)
    original_inode = @right_path.stat.ino
    plan = failing_store.plan(@left, @right)
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) do
      failing_store.apply(@left, @right, digest: @digest, fingerprint: plan.fingerprint, warnings: [])
    end
    assert_equal original_inode, @right_path.stat.ino
    batch = @store.batches.fetch(0)
    assert_equal original_inode, saved_original(batch.fetch("id")).stat.ino
    assert_equal "original_in_place", @store.state(batch)
    @store.finish(batch.fetch("id"), @right, :restore)
    assert_equal original_inode, @right_path.stat.ino
  end

  def test_restart_recovers_a_linked_copy_from_a_pending_manifest
    id = apply
    mark_pending(id)
    assert_equal "linked", @store.state(@store.read(id))
    @store.finish(id, @right, :restore)
    assert_equal "restored", @store.state(@store.read(id))
    refute_equal @left_path.stat.ino, @right_path.stat.ino
  end

  def test_restart_recovers_an_original_still_in_place
    id = apply
    mark_pending(id)
    backup = saved_original(id)
    stage = @right_path.dirname.join(".stage")
    File.link(backup, stage)
    File.rename(stage, @right_path)
    assert_equal "original_in_place", @store.state(@store.read(id))
    @store.finish(id, @right, :restore)
    assert_equal "restored", @store.state(@store.read(id))
    assert @right_path.exist?
    refute backup.exist?
  end

  private

  def apply(plan = @store.plan(@left, @right))
    @store.apply(@left, @right, digest: @digest, fingerprint: plan.fingerprint, warnings: [42])
  end

  def saved_original(id)
    @root.join(id, "files", "Library B", "Parts", "Duplicate.stl")
  end

  def mark_pending(id)
    manifest = @root.join(id, "manifest.json")
    manifest.write(JSON.generate(@store.read(id).merge("state" => "pending")))
  end
end
