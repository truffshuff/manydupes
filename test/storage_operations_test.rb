# frozen_string_literal: true

require "delegate"
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

  class CachedLinkStat < SimpleDelegator
    attr_reader :nlink, :ctime

    def initialize(stat, nlink:, ctime: stat.ctime)
      super(stat)
      @nlink = nlink
      @ctime = ctime
    end
  end

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

  def test_link_completion_tracks_current_storage_paths
    libraries = {1 => @library_a, 2 => @library_b}
    copies = [
      DuplicateAdjudicator::Index::Copy.new(library_id: 1, path: "Sets", filename: "Keeper.stl", size: 10),
      DuplicateAdjudicator::Index::Copy.new(library_id: 2, path: "Parts", filename: "Duplicate.stl", size: 10)
    ]
    refute DuplicateAdjudicator::StoragePreview.all_linked?(copies, libraries)

    id = apply
    assert DuplicateAdjudicator::StoragePreview.all_linked?(copies, libraries)
    assert DuplicateAdjudicator::StoragePreview.all_linked?(copies, libraries, distinct_paths: true)
    refute DuplicateAdjudicator::StoragePreview.all_linked?([copies.first, copies.first], libraries, distinct_paths: true)

    File.write(@left_path.dirname.join("Independent.stl"), "same bytes")
    extra = DuplicateAdjudicator::Index::Copy.new(library_id: 1, path: "Sets", filename: "Independent.stl", size: 10)
    refute DuplicateAdjudicator::StoragePreview.all_linked?(copies + [extra], libraries)

    @store.finish(id, @right, :restore)
    refute DuplicateAdjudicator::StoragePreview.all_linked?(copies, libraries)
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
    error = assert_raises(DuplicateAdjudicator::StorageOperations::Error) do
      failing_store.apply(@left, @right, digest: @digest, fingerprint: plan.fingerprint, warnings: [])
    end
    refute error.linked
    assert_match(/cross mount boundaries/, error.message)
    assert_equal original_inode, @right_path.stat.ino
    batch = @store.read(error.backup_id)
    assert_equal original_inode, saved_original(batch.fetch("id")).stat.ino
    assert_equal "original_in_place", @store.state(batch)
    @store.finish(batch.fetch("id"), @right, :restore)
    assert_equal original_inode, @right_path.stat.ino
  end

  def test_a_batch_failure_after_replacement_reports_the_link_and_recoverable_original
    failing_store = Class.new(DuplicateAdjudicator::StorageOperations) do
      private

      def write_manifest(batch)
        raise Errno::ENOSPC if batch["state"] == "linked"

        super
      end
    end.new([@library_a, @library_b], root: @root.to_s)
    original = @right_path.stat.ino
    plan = failing_store.plan(@left, @right)

    error = assert_raises(DuplicateAdjudicator::StorageOperations::Error) do
      failing_store.apply_batch_member(@left, @right, digest: @digest,
        fingerprint: plan.batch_fingerprint, warnings: [])
    end
    assert error.linked
    assert_match(/out of space/, error.message)
    assert_equal @left_path.stat.ino, @right_path.stat.ino
    assert_equal original, saved_original(error.backup_id).stat.ino
    assert_equal "linked", @store.state(@store.read(error.backup_id))

    @store.finish(error.backup_id, @right, :restore)
    assert_equal original, @right_path.stat.ino
  end

  def test_a_stale_backup_link_count_still_completes_the_link_and_preserves_the_original
    target_path = @right_path
    storage_class = Class.new(DuplicateAdjudicator::StorageOperations) do
      private

      define_method(:regular_stat) do |path|
        stat = super(path)
        if stat && path.to_s.start_with?("#{@root}/") && path.basename == target_path.basename &&
            !File.identical?(path, target_path)
          CachedLinkStat.new(stat, nlink: 2)
        else
          stat
        end
      end
    end
    store = storage_class.new([@library_a, @library_b], root: @root.to_s)
    original_inode = @right_path.stat.ino
    plan = store.plan(@left, @right)

    id = store.apply(@left, @right, digest: @digest, fingerprint: plan.fingerprint, warnings: [42])
    assert_equal "linked", store.read(id)["state"]
    assert_equal @left_path.stat.ino, @right_path.stat.ino
    assert_equal original_inode, saved_original(id).stat.ino
    assert_equal @digest, Digest::SHA512.file(saved_original(id)).hexdigest
    assert_equal [42], store.read(id)["warnings"]
  end

  def test_a_batch_accepts_refreshed_keeper_link_metadata_before_hashing_the_next_copy
    storage_class = Class.new(DuplicateAdjudicator::StorageOperations) do
      def plan(...)
        result = super
        source = result.pair.source
        if source.nlink > 1
          result.pair.source = CachedLinkStat.new(source, nlink: 1, ctime: source.ctime - 1)
        end
        result
      end
    end
    store = storage_class.new([@library_a, @library_b], root: @root.to_s)
    third_path = @right_path.dirname.join("More.stl")
    third_path.write("same bytes")
    third = Copy.new(Model.new(@library_b), "Parts/More.stl", 10, "third")
    plan = store.plan(@left, third)
    first_id = apply

    second_id = store.apply_batch_member(@left, third, digest: @digest,
      fingerprint: plan.batch_fingerprint, warnings: [])
    assert_equal @left_path.stat.ino, third_path.stat.ino
    assert_equal "linked", store.read(second_id)["state"]
    assert saved_original(first_id).exist?
    original = @root.join(second_id, "files", "Library B", "Parts", "More.stl")
    assert_equal @digest, Digest::SHA512.file(original).hexdigest
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

  def test_a_batch_reuses_the_keeper_and_rejects_a_stale_target
    third_path = @right_path.dirname.join("Third.stl")
    third_path.write("same bytes")
    third = Copy.new(Model.new(@library_b), "Parts/Third.stl", 10, "third")
    second_plan = @store.plan(@left, @right)
    third_plan = @store.plan(@left, third)
    first_id = @store.apply_batch_member(@left, @right, digest: @digest,
      fingerprint: second_plan.batch_fingerprint, warnings: [])
    third_path.write("new  bytes")
    assert_raises(DuplicateAdjudicator::StorageOperations::Error) do
      @store.apply_batch_member(@left, third, digest: @digest, fingerprint: third_plan.batch_fingerprint, warnings: [])
    end
    assert_equal "new  bytes", third_path.read
    assert_equal @left_path.stat.ino, @right_path.stat.ino
    assert saved_original(first_id).exist?

    third_path.write("same bytes")
    third_plan = @store.plan(@left, third)
    @store.apply_batch_member(@left, third, digest: @digest, fingerprint: third_plan.batch_fingerprint, warnings: [])
    assert_equal @left_path.stat.ino, third_path.stat.ino
  end

  def test_detach_after_purge_keeps_bytes_and_other_paths
    id = apply
    @store.finish(id, @right, :purge)
    plan = @store.independent_plan(@left, @right)
    @store.make_independent(@left, @right, digest: @digest, fingerprint: plan.fingerprint)

    refute_equal @left_path.stat.ino, @right_path.stat.ino
    assert_equal "same bytes", @right_path.read
    @right_path.write("new  bytes")
    assert_equal "same bytes", @left_path.read
    assert_equal "purged", @store.state(@store.read(id))
  end

  def test_detaching_with_a_retained_backup_leaves_it_restorable
    id = apply
    backup = saved_original(id)
    original_inode = backup.stat.ino
    plan = @store.independent_plan(@left, @right)
    @store.make_independent(@left, @right, digest: @digest, fingerprint: plan.fingerprint)
    assert_equal "detached", @store.state(@store.read(id))
    assert_equal backup.stat.blocks * 512, @store.pending_bytes(@store.batches)
    @store.finish(id, @right, :restore)
    assert_equal original_inode, @right_path.stat.ino
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
