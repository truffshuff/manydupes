# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module DuplicateAdjudicator
  class Index
    GROUPS_PER_PAGE = 24
    COPIES_PER_PAGE = 24
    SHA512 = /\A[0-9a-f]{128}\z/

    Group = Struct.new(:digest, :count, :model_count, :example, keyword_init: true)
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

    def groups(library_id:, search:, after:, limit: GROUPS_PER_PAGE + 1)
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
      candidates = candidates.where("model_files.digest > ?", after) if after
      rows = candidates.group("model_files.digest").having("COUNT(*) > 1").order("model_files.digest")
        .limit(limit).pluck(:digest, Arel.sql("COUNT(*)"), Arel.sql("COUNT(DISTINCT model_files.model_id)"),
          Arel.sql("MIN(model_files.id)"))
      examples = file_records(@files.where(id: rows.map(&:last))).index_by(&:id)
      rows.filter_map do |digest, count, model_count, id|
        example = examples[id]
        Group.new(digest: digest, count: count, model_count: model_count, example: example) if example
      end
    end

    def snapshot(digest, lock: false)
      group = @candidates.where(digest: digest).order("model_files.id")
      group = group.lock if lock
      copies = group.pluck("model_files.id", "model_files.public_id", "model_files.model_id", "models.library_id", "models.path",
          "model_files.filename", "models.preview_file_id", "models.entrypoint_id", "model_files.presupported",
          "model_files.size", "models.name").map do |id, public_id, model_id, library_id, path, filename, preview_id, entrypoint_id, support, size, name|
        Copy.new(id: id, public_id: public_id, model_id: model_id, library_id: library_id, path: path, filename: filename,
          preview: preview_id == id, entrypoint: entrypoint_id == id, support: support, size: size, name: name)
      end

      Snapshot.new(copies: copies, path_counts: copies.map(&:storage_key).tally,
        fingerprint: Digest::SHA256.hexdigest(JSON.generate(copies.map(&:to_a))))
    end

    def records(copies, digest:)
      file_records(@candidates.where(id: copies.map(&:id), digest: digest)).index_by(&:id)
    end

    def model_file_counts(model_ids)
      @files.without_special.where(model_id: model_ids).group("model_files.model_id").count
    end

    private

    def file_records(relation)
      relation.preload(model: :library).to_a
    end
  end
end
