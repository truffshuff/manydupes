# frozen_string_literal: true

require "pathname"

module DuplicateAdjudicator
  class StoragePreview
    Result = Struct.new(:status, :bytes, :source_path, :target_path, :source, :target, keyword_init: true)

    def self.call(left, right)
      libraries = [left.model.library, right.model.library]
      return Result.new(status: :nonlocal) unless libraries.all? { |library| library.storage_service == "filesystem" }

      source_path, target_path = [left, right].map { |file| indexed_path(file) }
      return Result.new(status: :unavailable) unless source_path && target_path

      source, replica = [source_path, target_path].map(&:lstat)
      return Result.new(status: :unavailable) unless source.file? && replica.file?
      return Result.new(status: :same_file) if source.dev == replica.dev && source.ino == replica.ino
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

    def self.indexed_path(file)
      library = file.model.library
      return unless library.storage_service == "filesystem"
      relative = Pathname.new(file.path_within_library)
      return if relative.absolute? || relative.each_filename.any? { |part| part == ".." }

      root = Pathname.new(library.path).realpath
      path = root.join(relative).cleanpath
      return unless path != root && path.realpath == path

      path if path.lstat.file?
    end
  end
end
