# frozen_string_literal: true

require "openssl"

module DuplicateAdjudicator
  class ReviewsController < ::ApplicationController
    # This GET serves a fixed script from the plugin package. Verification POSTs use Rails CSRF protection.
    skip_forgery_protection only: :script

    before_action :authenticate_admin_user!
    before_action :private_response
    before_action :require_html, only: [:index, :show, :verify]

    helper_method :queue_url, :group_url, :verify_url, :asset_url, :core_routes, :roles_for,
      :native_file_url, :review_namespace

    def index
      @title = "Duplicate Adjudicator"
      set_filters
      rows = inventory.groups(library_id: @library&.id, search: @search, after: @after)
      @groups = rows.first(Index::GROUPS_PER_PAGE)
      @next_page = @groups.last.digest if rows.size > Index::GROUPS_PER_PAGE && @groups.any?
    end

    def show
      authorize ::Library, :index?
      return head :not_found unless load_group
    end

    def verify
      authorize ::Library, :index?
      return head :not_found unless load_group

      file = [@left, @right].find { |candidate| candidate.public_id == params[:copy] }
      return head :not_found unless file

      @verification = {id: file.id, result: Verification.call(file, @digest)}
      render :show
    end

    def theme
      serve_asset("theme.css", "text/css")
    end

    def script
      serve_asset("review.js", "application/javascript")
    end

    private

    def is_api_request?
      false
    end

    def require_html
      head :not_acceptable unless request.format.html?
    end

    def private_response
      response.headers["Cache-Control"] = "private, no-store"
      response.headers["X-Content-Type-Options"] = "nosniff"
      @indexing_directives = "noindex, noai, noimageai"
      response.headers["X-Robots-Tag"] = @indexing_directives
    end

    def serve_asset(name, mime)
      authorize ::Library, :index?
      response.headers["Cross-Origin-Resource-Policy"] = "same-origin"
      render plain: Engine.root.join("lib/duplicate_adjudicator", name).read, content_type: mime
    end

    def set_filters
      @libraries = policy_scope(::Library).to_a
      @library = @libraries.find { |record| record.public_id == params[:library] } if params[:library].is_a?(String)
      @search = params[:q].is_a?(String) ? params[:q].strip[0, 160] : ""
      @after = checksum(params[:after])
    end

    def inventory
      @inventory ||= begin
        libraries = @libraries.map(&:id)
        models = policy_scope(::Model).local.where(library_id: libraries).reorder(nil)
        files = policy_scope(::ModelFile).joins(:model).where(model_id: models.select(:id))
        Index.new(files)
      end
    end

    def load_group
      @digest = checksum(params[:digest])
      return false unless @digest

      set_filters
      @snapshot = inventory.snapshot(@digest)
      return false if @snapshot.copies.size < 2

      @title = "Compare duplicate files"
      @total_pages = (@snapshot.copies.size + Index::COPIES_PER_PAGE - 1) / Index::COPIES_PER_PAGE
      raw_page = params[:copies].to_s
      @page = raw_page.match?(/\A[0-9]{1,9}\z/) ? raw_page.to_i.clamp(1, @total_pages) : 1
      copies = @snapshot.copies.slice((@page - 1) * Index::COPIES_PER_PAGE, Index::COPIES_PER_PAGE)
      @copy_by_id = @snapshot.copies.index_by(&:id)
      selected = @snapshot.copies.select { |copy| [params[:left], params[:right]].include?(copy.public_id) }
      @records = inventory.records((copies + selected).uniq, digest: @digest)
      @copies = copies.select { |copy| @records.key?(copy.id) }
      return false if @copies.empty?

      @left = file_choice(params[:left]) || @records.fetch(@copies.first.id)
      @right = file_choice(params[:right], excluding: @left.id) ||
        @copies.filter_map { |copy| @records[copy.id] }.find { |file| file.id != @left.id }
      # Keep both cards available when the last page has just one copy.
      if @right.nil?
        other = @snapshot.copies.find { |copy| copy.id != @left.id }
        @records.merge!(inventory.records([other], digest: @digest))
        @right = @records[other.id]
      end
      return false unless @right

      @compare_copies = (@copies + [@copy_by_id.fetch(@left.id), @copy_by_id.fetch(@right.id)]).uniq
      @model_file_counts = inventory.model_file_counts(@records.values.map(&:model_id).uniq)
      @next_group = inventory.groups(library_id: @library&.id, search: @search, after: @digest, limit: 1).first
      true
    end

    def file_choice(public_id, excluding: nil)
      @records.values.find { |file| file.public_id == public_id && file.id != excluding }
    end

    def checksum(value)
      value if value.is_a?(String) && Index::SHA512.match?(value)
    end

    def filter_params
      {library: @library&.public_id, q: @search.presence, after: @after}
    end

    def queue_url(**options)
      mounted_url("/", **filter_params.merge(options))
    end

    def group_url(digest = @digest, **options)
      mounted_url("/group/#{digest}", **filter_params.merge(options))
    end

    def verify_url
      mounted_url("/group/#{@digest}/verify", **filter_params.merge(copies: @page,
        left: @left.public_id, right: @right.public_id))
    end

    def asset_url(name)
      mounted_url("/#{name}")
    end

    def mounted_url(path, **query)
      prefix = request.script_name.to_s.chomp("/")
      encoded = query.compact.to_query
      encoded.empty? ? prefix + path : "#{prefix}#{path}?#{encoded}"
    end

    def core_routes
      Rails.application.routes.url_helpers
    end

    def native_file_url(file, **options)
      core_routes.model_model_file_path(file.model, file, **options)
    end

    def roles_for(copy, file)
      roles = []
      roles << "Model preview" if copy.preview
      roles << "Entrypoint" if copy.entrypoint
      if file.is_3d_model? || file.is_slicer_file?
        roles << "Presupported" if copy.support == true
        roles << "Unsupported" if copy.support == false
      end
      roles << "Shared path" if @snapshot.shared_path?(copy)
      roles
    end

    def review_namespace
      key = Rails.application.key_generator.generate_key("duplicate-adjudicator/reviews", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, "#{request.script_name}\0#{current_user.id}")
    end
  end
end
