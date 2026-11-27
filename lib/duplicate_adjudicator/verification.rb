# frozen_string_literal: true

require "digest"

module DuplicateAdjudicator
  class Verification
    LIMIT = 64 * 1024 * 1024
    CHUNK = 128 * 1024

    def self.call(file, expected_digest, limit: LIMIT)
      return :too_large if file.size > limit

      library = file.model.library
      attachment = file.attachment
      unless attachment && attachment.id == file.path_within_library &&
          attachment.storage_key.to_s == library.storage_key.to_s
        return :unavailable
      end

      return :missing unless file.exists_on_storage?

      bytes = 0
      digest = Digest::SHA512.new
      stream_options = (library.storage_service == "s3") ? {rewindable: false} : {}
      attachment.open(**stream_options) do |stream|
        while (chunk = stream.read([CHUNK, limit - bytes + 1].min))
          bytes += chunk.bytesize
          return :too_large if bytes > limit
          digest.update(chunk)
        end
      end
      (digest.hexdigest == expected_digest) ? :verified : :different
    rescue Errno::ENOENT
      :missing
    rescue => error
      # Storage adapters have independent error hierarchies and may include private paths in messages.
      Rails.logger.info("Duplicate Adjudicator verification failed (#{error.class})")
      :unavailable
    end
  end
end
