# frozen_string_literal: true

require "digest"
require "json"
require "pathname"
require "securerandom"
require "time"

module DuplicateAdjudicator
  class StorageOperations
    class Error < StandardError; end

    DEFAULT_ROOT = "/mnt/3DPrints/duplicates"
    ID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/
    READ_FILE = File::RDONLY | File::NOFOLLOW | File::NONBLOCK

    Plan = Struct.new(:pair, :source, :target, :fingerprint, keyword_init: true)

    attr_reader :root

    def initialize(libraries, root: ENV.fetch("DUPLICATE_ADJUDICATOR_BACKUP_ROOT", DEFAULT_ROOT))
      configured = Pathname.new(root)
      unless configured.absolute? && configured == configured.cleanpath && configured != configured.parent
        raise Error, "Configure an absolute, normalized restore folder inside the bind mount."
      end

      @mount = configured.parent.realpath
      @root = @mount.join(configured.basename)
      libraries.select { |library| library.storage_service == "filesystem" }.each do |library|
        next if library.path.to_s.empty?

        path = Pathname.new(library.path).expand_path
        library_root = path.exist? ? path.realpath : path
        if inside?(@root, library_root) || inside?(library_root, @root)
          raise Error, "The restore folder must be outside all Manyfold libraries."
        end
      end
      safe_directory(@root) if @root.exist? || @root.symlink?
    rescue SystemCallError, ArgumentError
      raise Error, "Manyfold cannot access the configured restore folder’s parent inside the container."
    end

    def plan(left, right, pair: StoragePreview.call(left, right))
      unless pair.status == :possible
        raise Error, "Select two independent filesystem files that pass the disk savings check."
      end

      paths = [pair.source_path, pair.target_path]
      unless paths.all? { |path| inside?(path, @mount) && !inside?(path, @root) }
        raise Error, "Both copies must be inside the restore folder’s parent bind mount."
      end

      directory = @root.exist? ? safe_directory(@root) : @mount
      unless directory.writable? && pair.target_path.dirname.writable? && directory.stat.dev == pair.target.dev
        raise Error, "The restore folder and duplicate’s directory must be writable on the same filesystem."
      end

      source, target = paths.map { |path| path.relative_path_from(@mount).to_s }
      fingerprint = Digest::SHA256.hexdigest(JSON.generate(
        [@root.to_s, source, target, stamp(pair.source), stamp(pair.target)]
      ))
      Plan.new(pair: pair, source: source, target: target, fingerprint: fingerprint)
    rescue SystemCallError, ArgumentError
      raise Error, "The files or restore folder could not be checked."
    end

    def apply(left, right, digest:, fingerprint:, warnings:)
      with_lock do
        checked = plan(left, right)
        unless checked.fingerprint == fingerprint
          raise Error, "The files changed after the preview. Run the disk savings check again."
        end

        pair = checked.pair
        verify!(pair.source_path, digest, pair.source)
        verify!(pair.target_path, digest, pair.target)

        id = SecureRandom.uuid
        batch = {
          "id" => id, "state" => "pending", "created_at" => Time.now.utc.iso8601,
          "digest" => digest, "source" => checked.source, "target" => checked.target,
          "target_file" => right.public_id, "allocation_bytes" => pair.bytes,
          "keeper_inode" => identity(pair.source), "original_inode" => identity(pair.target),
          "warnings" => warnings
        }
        batch_directory = @root.join(id)
        make_directory(batch_directory)
        write_manifest(batch)

        backup = backup_path(batch)
        make_backup_directories(batch_directory, backup.dirname)
        assert_unchanged!(pair.target_path, pair.target)
        File.link(pair.target_path, backup)
        sync_directory(backup.dirname)
        unless identity(regular_stat(backup)) == batch.fetch("original_inode")
          raise Error, "The duplicate changed while its backup was being made. Check Restore backups."
        end

        replace_with_link(pair.source_path, pair.target_path, linking: pair.source, replacing: pair.target,
          expected_source_links: pair.source.nlink, expected_target_links: pair.target.nlink + 1)
        assert_unchanged!(backup, pair.target)
        write_manifest(batch.merge("state" => "linked"))
        id
      end
    rescue Errno::EXDEV
      raise Error, "The paths are on different mounts. Check the container’s bind mount before retrying."
    rescue SystemCallError
      raise Error, "The storage operation could not finish. Check Restore backups for any retained original."
    end

    def batches
      return [] unless @root.exist?

      safe_directory(@root)
      @root.children.select { |path| ID.match?(path.basename.to_s) }.filter_map do |path|
        read(path.basename.to_s)
      rescue Error
        nil
      end.sort_by { |batch| [batch["created_at"], batch["id"]] }.reverse
    rescue SystemCallError
      raise Error, "Manyfold could not list the restore folder."
    end

    def read(id)
      return unless id.is_a?(String) && ID.match?(id)

      directory = @root.join(id)
      return unless directory.exist?

      safe_directory(@root)
      safe_directory(directory)
      manifest = directory.join("manifest.json")
      content = File.open(manifest, READ_FILE) { |file| file.read(65_537) }
      batch = JSON.parse(content)
      unless batch.is_a?(Hash) && batch["id"] == id && batch["created_at"].is_a?(String) &&
          batch["digest"].is_a?(String) && Index::SHA512.match?(batch["digest"]) &&
          valid_relative?(batch["target"]) && valid_relative?(batch["source"]) &&
          batch["target_file"].is_a?(String) && valid_inode?(batch["keeper_inode"]) &&
          valid_inode?(batch["original_inode"]) && batch["warnings"].is_a?(Array) &&
          batch["warnings"].all? { |warning| warning.is_a?(Integer) } &&
          %w[pending linked restored purged].include?(batch["state"])
        raise Error, "This restore record is invalid."
      end
      batch
    rescue Errno::ENOENT
      nil
    rescue SystemCallError, JSON::ParserError, TypeError
      raise Error, "This restore record could not be read."
    end

    def state(batch)
      return batch.fetch("state") if %w[restored purged].include?(batch.fetch("state"))

      live = identity(regular_stat(@mount.join(batch.fetch("target"))))
      saved = identity(regular_stat(backup_path(batch)))
      return "linked" if live == batch["keeper_inode"] && saved == batch["original_inode"]
      return "original_in_place" if live == batch["original_inode"] && saved == batch["original_inode"]
      return "restored" if live == batch["original_inode"] && !saved && batch["state"] == "linked"
      return "purged" if live == batch["keeper_inode"] && !saved && batch["state"] == "linked"
      return "original_in_place" if live == batch["original_inode"] && !saved

      "attention"
    rescue SystemCallError
      "attention"
    end

    def finish(id, file, action)
      with_lock(create: false) do
        batch = read(id)
        raise Error, "This restore record is unavailable." unless batch

        state = state(batch)
        return batch if (action == :restore && state == "restored") || (action == :purge && state == "purged")

        unless state == "linked" || (action == :restore && state == "original_in_place")
          raise Error, "The paths changed after the operation. The backup was left in place."
        end

        live = @mount.join(batch.fetch("target"))
        unless file && file.public_id == batch.fetch("target_file") && StoragePreview.indexed_path(file) == live
          raise Error, "The Manyfold file no longer points to the recorded path. Restore the backup manually."
        end

        backup = backup_path(batch)
        digest = batch.fetch("digest")
        original_in_place = state == "original_in_place"
        live_identity = original_in_place ? batch["original_inode"] : batch["keeper_inode"]
        current = verify_current!(live, digest, live_identity)
        saved = verify_current!(backup, digest, batch["original_inode"]) if !original_in_place || backup.exist?
        if action == :restore && !original_in_place
          replace_with_link(backup, live, linking: saved, replacing: current,
            expected_source_links: saved.nlink, expected_target_links: current.nlink)
        end

        if saved
          unless identity(regular_stat(backup)) == batch["original_inode"]
            raise Error, "The saved file changed. The backup was left in place."
          end

          if action == :purge
            assert_unchanged!(live, current)
            assert_unchanged!(backup, saved)
          end
          File.unlink(backup)
          sync_directory(backup.dirname)
        end
        finished = batch.merge("state" => action == :restore ? "restored" : "purged")
        write_manifest(finished)
        finished
      end
    rescue SystemCallError
      raise Error, "The operation could not finish. Reload Restore backups to see its current state."
    end

    private

    def with_lock(create: true)
      make_directory(@root) if create && !@root.exist?
      safe_directory(@root)
      File.open(@root.join(".adjudicator.lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        unless lock.stat.file? && lock.flock(File::LOCK_EX | File::LOCK_NB)
          raise Error, "Another disk operation is running. Try again after it finishes."
        end

        yield
      end
    end

    def replace_with_link(source, target, linking:, replacing:, expected_source_links:, expected_target_links:)
      stage = target.dirname.join(".duplicate-adjudicator-#{SecureRandom.uuid}")
      assert_unchanged!(source, linking, links: expected_source_links)
      File.link(source, stage)
      unless identity(regular_stat(stage)) == identity(linking)
        raise Error, "The source changed while the temporary link was being created."
      end

      assert_unchanged!(source, linking, links: expected_source_links + 1)
      assert_unchanged!(target, replacing, links: expected_target_links)
      File.rename(stage, target)
      sync_directory(target.dirname)
      assert_unchanged!(source, linking, links: expected_source_links + 1)
      assert_unchanged!(target, linking, links: expected_source_links + 1)
    ensure
      if stage && identity(regular_stat(stage)) == identity(linking)
        File.unlink(stage)
      end
    end

    def verify_current!(path, digest, expected_inode)
      stat = regular_stat(path)
      unless stat && identity(stat) == expected_inode
        raise Error, "The stored file changed. The backup was left in place."
      end

      verify!(path, digest, stat)
      stat
    end

    def verify!(path, digest, expected)
      hash = Digest::SHA512.new
      File.open(path, READ_FILE) do |file|
        unless file.stat.file? && stamp(file.stat) == stamp(expected)
          raise Error, "The file changed during verification. Run the disk savings check again."
        end
        while (chunk = file.read(1024 * 1024))
          hash.update(chunk)
        end
        unless stamp(file.stat) == stamp(expected) && hash.hexdigest == digest
          raise Error, "The stored bytes differ from the indexed checksum. Rescan before linking."
        end
        file.fsync
      end
      assert_unchanged!(path, expected)
    end

    def assert_unchanged!(path, expected, links: expected.nlink)
      current = regular_stat(path)
      unless current && content_stamp(current) == content_stamp(expected) && current.nlink == links
        raise Error, "A stored path changed. Check Restore backups before retrying."
      end
    end

    def stamp(stat)
      [content_stamp(stat), stat.ctime.to_r.to_s, stat.nlink]
    end

    def content_stamp(stat)
      [identity(stat), stat.size, stat.mtime.to_r.to_s, stat.mode, stat.uid, stat.gid]
    end

    def identity(stat)
      [stat.dev, stat.ino] if stat
    end

    def regular_stat(path)
      return unless path.realpath == path

      stat = path.lstat
      stat if stat.file?
    rescue Errno::ENOENT, Errno::ELOOP, Errno::ENOTDIR
      nil
    end

    def make_backup_directories(batch_directory, destination)
      directory = batch_directory
      destination.relative_path_from(batch_directory).each_filename do |part|
        directory = directory.join(part)
        make_directory(directory)
      end
    end

    def make_directory(path)
      Dir.mkdir(path, 0o700)
      sync_directory(path.dirname)
    rescue Errno::EEXIST
      safe_directory(path)
    end

    def safe_directory(path)
      unless path.realpath == path && path.directory?
        raise Error, "The restore directory contains a symbolic link or is unavailable."
      end

      path
    end

    def sync_directory(path)
      File.open(path, File::RDONLY, &:fsync)
    end

    def backup_path(batch)
      @root.join(batch.fetch("id"), "files", batch.fetch("target"))
    end

    def write_manifest(batch)
      directory = safe_directory(@root.join(batch.fetch("id")))
      temporary = directory.join(".manifest-#{SecureRandom.uuid}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |file|
        file.write(JSON.generate(batch))
        file.flush
        file.fsync
      end
      File.rename(temporary, directory.join("manifest.json"))
      sync_directory(directory)
    ensure
      File.unlink(temporary) if temporary&.exist?
    end

    def valid_inode?(value)
      value.is_a?(Array) && value.size == 2 && value.all? { |item| item.is_a?(Integer) }
    end

    def valid_relative?(value)
      return false unless value.is_a?(String) && !value.empty? && !value.include?("\0")

      path = Pathname.new(value)
      !path.absolute? && path != Pathname.new(".") && path == path.cleanpath &&
        path.each_filename.none? { |part| part == ".." }
    end

    def inside?(path, directory)
      path == directory || path.to_s.start_with?("#{directory.to_s.chomp("/")}/")
    end
  end
end
