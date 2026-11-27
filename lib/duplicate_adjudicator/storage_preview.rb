# frozen_string_literal: true

require "pathname"

module DuplicateAdjudicator
  class StoragePreview
    ISSUES = {
      nonlocal: "Both copies must be in filesystem-backed libraries.",
      unavailable: "A regular file could not be read at one of the indexed paths.",
      size_changed: "The stored size differs from the index. Rescan the file before linking.",
      different_filesystems: "The files are on different devices. Hard links require the same mounted filesystem.",
      linked_elsewhere: "This copy already has other hard links to a different stored file.",
      different_attributes: "The files have different ownership or permissions."
    }.freeze

    Result = Struct.new(:status, :bytes, :source_path, :target_path, :source, :target)

    def self.call(left, right)
      libraries = [left.model.library, right.model.library]
      return Result.new(status: :nonlocal) unless libraries.all? { |library| library.storage_service == "filesystem" }

      source_path, target_path = [left, right].map { |file| indexed_path(file) }
      return Result.new(status: :unavailable) unless source_path && target_path

      source, replica = [source_path, target_path].map(&:lstat)
      return Result.new(status: :unavailable) unless source.file? && replica.file?
      if source.dev == replica.dev && source.ino == replica.ino
        return Result.new(status: :same_file, source_path: source_path, target_path: target_path)
      end
      return Result.new(status: :size_changed) if source.size != left.size || replica.size != right.size
      return Result.new(status: :different_filesystems) if source.dev != replica.dev
      return Result.new(status: :linked_elsewhere) if replica.nlink > 1
      if [source.uid, source.gid, source.mode] != [replica.uid, replica.gid, replica.mode]
        return Result.new(status: :different_attributes)
      end

      blocks = replica.blocks
      Result.new(status: :possible, bytes: blocks && blocks * 512, source_path: source_path,
        target_path: target_path, source: source, target: replica)
    rescue SystemCallError, ArgumentError
      Result.new(status: :unavailable)
    end

    def self.all_linked?(copies, libraries, distinct_paths: false)
      return false if copies.size < 2

      inode = nil
      first_path = nil
      different_path = false
      linked = copies.all? do |copy|
        library = libraries[copy.library_id]
        path = resolve_path(library, File.join(copy.path, copy.filename))
        stat = path&.lstat
        next false unless stat&.file? && stat.size == copy.size
        next false if distinct_paths && stat.nlink < 2

        first_path ||= path
        different_path ||= path != first_path
        identity = [stat.dev, stat.ino]
        inode ||= identity
        inode == identity
      end
      linked && (!distinct_paths || different_path)
    rescue SystemCallError, ArgumentError
      false
    end

    def self.indexed_path(file)
      path = resolve_path(file.model.library, file.path_within_library)
      path if path&.lstat&.file?
    end

    def self.resolve_path(library, indexed)
      return unless library&.storage_service == "filesystem"

      relative = Pathname.new(indexed)
      return if relative.absolute? || relative.each_filename.any? { |part| part == ".." }

      root = Pathname.new(library.path).realpath
      path = root.join(relative).cleanpath
      path if path != root && path.realpath == path
    end
    private_class_method :resolve_path
  end
end
