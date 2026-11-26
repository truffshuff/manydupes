# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"

module DuplicateAdjudicator
  class ReviewStore
    class Error < StandardError; end

    def initialize(root, account)
      raise Error unless /\A[0-9]+\z/.match?(account.to_s)

      @root = Pathname.new(root).expand_path
      @account = @root.join(account.to_s)
    end

    def read(digest)
      return unless @account.directory?

      checked_directory(@root)
      checked_directory(@account)
      File.open(record_path(digest), File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        raise Error unless file.stat.file?

        raw = JSON.parse(file.read(512 * 1024))
        raise Error unless raw.is_a?(Hash) && raw["copies"].is_a?(Array)

        raw
      end
    rescue Errno::ENOENT
      nil
    rescue SystemCallError, JSON::ParserError, TypeError
      raise Error
    end

    def update(digest, fingerprint, import: false)
      make_directory(@root)
      make_directory(@account)
      File.open(@account.join(".lock"), File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        raise Error unless lock.stat.file? && lock.flock(File::LOCK_EX)

        current = read(digest)
        return if import && current

        state = current if current && current["fingerprint"] == fingerprint
        state ||= {"fingerprint" => fingerprint, "copies" => []}
        yield state
        write(record_path(digest), state)
      end
    rescue SystemCallError
      raise Error
    end

    private

    def record_path(digest)
      raise Error unless Index::SHA512.match?(digest.to_s)

      @account.join("#{digest}.json")
    end

    def make_directory(path)
      Dir.mkdir(path, 0o700)
      File.open(path.dirname, File::RDONLY, &:fsync)
    rescue Errno::EEXIST
      checked_directory(path)
    end

    def checked_directory(path)
      raise Error unless path.directory? && !path.symlink?
    end

    def write(destination, state)
      temporary = @account.join(".review-#{SecureRandom.uuid}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(state))
        file.flush
        file.fsync
      end
      File.rename(temporary, destination)
      File.open(@account, File::RDONLY, &:fsync)
    ensure
      File.unlink(temporary) if temporary&.exist?
    end
  end
end
