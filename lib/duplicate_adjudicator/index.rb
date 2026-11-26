# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module DuplicateAdjudicator
  class Index
    GROUPS_PER_PAGE = 24
    COPIES_PER_PAGE = 24
    SHA512 = /\A[0-9a-f]{128}\z/

    SAVINGS = "SUM(model_files.size) - MAX(model_files.size)"

    Group = Struct.new(:digest, :count, :model_count, :savings, :example, keyword_init: true) do
      def cursor(sort)
        sort == "savings" ? "#{savings}-#{digest}" : digest
      end
    end
    Copy = Struct.new(:id, :public_id, :model_id, :library_id, :path, :filename, :preview, :entrypoint, :support,
      :size, :name, keyword_init: true) do
      def indexed_path
        Pathname.new(File.join(path, filename)).cleanpath.to_s
      end

      def storage_key
        [library_id, indexed_path]
      end
    end

    Snapshot = Struct.new(:copies, :path_counts, :fingerprint, keyword_init: true) do
      def shared_path?(copy)
        path_counts.fetch(copy.storage_key) > 1
      end
    end

    def initialize(files)
      @files = files.reorder(nil)
      @candidates = @files.without_special.where("model_files.size > 0").where.not(digest: [nil, ""])
    end

    def groups(library_id:, search:, after:, sort: nil, limit: GROUPS_PER_PAGE + 1)
      seeds = @candidates
      seeds = seeds.where(models: {library_id: library_id}) if library_id
      if search.present?
        literal = ::ModelFile.sanitize_sql_like(search.downcase, "!")
        seeds = seeds.where(
          "LOWER(model_files.filename) LIKE :search ESCAPE '!' OR LOWER(models.path) LIKE :search ESCAPE '!' OR LOWER(models.name) LIKE :search ESCAPE '!'",
          search: "%#{literal}%"
        )
      end
      candidates = @candidates
      candidates = candidates.where(digest: seeds.select(:digest)) if library_id || search.present?
      grouped = candidates.group("model_files.digest").having("COUNT(*) > 1")
      if sort == "savings"
        if after
          bytes, digest = after.split("-", 2)
          grouped = grouped.having("(#{SAVINGS}) < :size OR ((#{SAVINGS}) = :size AND model_files.digest > :digest)",
            size: bytes.to_i, digest: digest)
        end
        grouped = grouped.order(Arel.sql("(#{SAVINGS}) DESC"), "model_files.digest")
      else
        grouped = grouped.where("model_files.digest > ?", after) if after
        grouped = grouped.order("model_files.digest")
      end
      rows = grouped.limit(limit).pluck(:digest, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT model_files.model_id)"),
        Arel.sql(SAVINGS), Arel.sql("MIN(model_files.id)"))
      examples = file_records(@files.where(id: rows.map(&:last))).index_by(&:id)
      rows.filter_map do |digest, count, model_count, savings, id|
        example = examples[id]
        Group.new(digest: digest, count: count, model_count: model_count, savings: savings.to_i, example: example) if example
      end
    end

    def snapshot(digest, lock: false)
      snapshots([digest], lock: lock).fetch(digest) { build_snapshot([]) }
    end

    def snapshots(digests, lock: false)
      return {} if digests.empty?

      group = @candidates.where(digest: digests).order("model_files.id")
      group = group.lock if lock
      rows = group.pluck("model_files.digest", "model_files.id", "model_files.public_id", "model_files.model_id",
        "models.library_id", "models.path", "model_files.filename", "models.preview_file_id", "models.entrypoint_id",
        "model_files.presupported", "model_files.size", "models.name")
      rows.group_by(&:first).transform_values do |group_rows|
        copies = group_rows.map do |_digest, id, public_id, model_id, library_id, path, filename, preview_id, entrypoint_id, support, size, name|
          Copy.new(id: id, public_id: public_id, model_id: model_id, library_id: library_id, path: path, filename: filename,
            preview: preview_id == id, entrypoint: entrypoint_id == id, support: support, size: size, name: name)
        end
        build_snapshot(copies)
      end
    end

    def records(copies, digest:)
      @candidates.where(id: copies.map(&:id), digest: digest).preload(model: [:library, :collections]).index_by(&:id)
    end

    def model_file_counts(model_ids)
      @files.without_special.where(model_id: model_ids).group("model_files.model_id").count
    end

    private

    def build_snapshot(copies)
      Snapshot.new(copies: copies, path_counts: copies.map(&:storage_key).tally,
        fingerprint: Digest::SHA256.hexdigest(JSON.generate(copies.map(&:to_a))))
    end

    def file_records(relation)
      relation.preload(model: :library).to_a
    end
  end
end
