# frozen_string_literal: true

require "openssl"
require "set"

module DuplicateAdjudicator
  class ReviewsController < ::ApplicationController
    QUEUE_REFILL_SIZE = 96

    # This GET serves a fixed script from the plugin package. Verification POSTs use Rails CSRF protection.
    skip_forgery_protection only: :script

    before_action :authenticate_admin_user!
    before_action :private_response
    before_action :require_html, only: [:index, :show, :verify, :storage, :warnings, :link_copies, :backups, :restore_copy, :purge_backup, :decision, :import_reviews, :independent, :make_independent]

    helper_method :queue_url, :group_url, :verify_url, :asset_url, :core_routes, :roles_for,
      :native_file_url, :review_namespace, :group_action_url, :backups_url, :backup_action_url, :review_import_url, :copy_label

    def index
      @title = "Duplicate Adjudicator"
      set_filters
      refill = params[:refill] == "1" && @review_view.nil?
      @queue_entry_after = refill ? queue_cursor(params[:queue_after]) : @after
      size = refill ? QUEUE_REFILL_SIZE : Index::GROUPS_PER_PAGE
      rows = inventory.groups(library_id: @library&.id, search: @search, after: @after, sort: @sort, limit: size + 1)
      @groups = rows.first(size)
      load_queue_review
      @next_page = @groups.last.cursor(@sort) if rows.size > size && @groups.any?
      render partial: "queue_refill", layout: false if refill
    end

    def show
      authorize ::Library, :index?
      return head :not_found unless load_group

      render_comparison
    end

    def verify
      authorize ::Library, :index?
      return head :not_found unless load_group

      file = file_choice(params[:copy])
      return head :not_found unless file

      @verification = {id: file.id, result: Verification.call(file, @digest)}
      render_comparison
    end

    def storage
      authorize ::Library, :index?
      return head :not_found unless load_group

      if params[:scope] == "group"
        return head :forbidden if ::SiteSettings.demo_mode_enabled?
        prepare_group_plan
        return render_comparison
      end

      if params[:bulk] == "1"
        return head :forbidden if ::SiteSettings.demo_mode_enabled?
        targets = selected_targets(params[:targets])
        if targets
          prepare_batch_plan(targets.map { |file| @copy_by_id.fetch(file.id) }, keeper: @left, whole_group: false)
        else
          @storage_error = "Choose at least one copy from this page to link to the left copy."
        end
        return render_comparison
      end

      @storage = StoragePreview.call(@left, @right)
      if @storage.status == :possible && !::SiteSettings.demo_mode_enabled?
        prepare_storage_plan
      end
      render_comparison
    end

    def link_copies
      authorize ::Library, :index?
      return head :forbidden if ::SiteSettings.demo_mode_enabled?
      return head :not_found unless load_group

      payload = storage_verifier.verified(params[:plan].to_s, purpose: "link-copies")
      if payload.is_a?(Hash) && payload["group"]
        keeper = @records[@preferred_copy&.id]
        context = group_storage_context(@preferred_copy) if keeper
      else
        context = storage_context
      end
      unless params[:confirm] == "1" && payload.is_a?(Hash) && context && payload["context"] == context
        @storage_error = "This confirmation expired or the comparison changed. Review the hard-link plan again."
        return render_comparison
      end

      if payload["targets"].is_a?(Hash)
        fingerprints = payload["targets"]
        if payload["group"]
          selected = params[:targets]
          unless selected.is_a?(Array) && selected.any? && selected.size <= fingerprints.size &&
              selected.all? { |id| fingerprints.key?(id) }
            prepare_group_plan
            @storage_error ||= "Select at least one eligible copy from the reviewed plan."
            return render_comparison
          end
          selected = selected.to_set
          targets = @snapshot.copies.select { |copy| selected.include?(copy.public_id) }
        else
          keeper = @left
          files = selected_targets(fingerprints.keys)
          return head :bad_request unless files

          targets = files.map { |file| @copy_by_id.fetch(file.id) }
        end
        apply_batch_plan(keeper, targets, fingerprints, acknowledge: params[:acknowledge] == "1")
        refresh_link_completion
        if payload["group"]
          @batch_results.concat(@snapshot.copies.filter_map do |copy|
            {copy: copy, status: :skipped} if fingerprints.key?(copy.public_id) && !selected.include?(copy.public_id)
          end)
        end
        return render_comparison
      end

      warning_ids = planned_warning_ids if params[:acknowledge] == "1"
      batch_id = storage_operations.apply(@left, @right, digest: @digest, fingerprint: payload.fetch("fingerprint"),
        warnings: warning_ids || [])
      warning_error = update_storage_warnings(warning_ids, ignored: true)
      @storage = StoragePreview.call(@left, @right)
      @storage_feedback = "Both paths now share the same stored file. The original is in Restore backups."
      @storage_error = warning_error
      @backup_anchor = "backup-#{batch_id}"
      refresh_link_completion
      load_warning_counts
      render_comparison
    rescue StorageOperations::Error => error
      @storage_error = error.linked ? "The paths share storage. Check the saved original. #{error.message}" : error.message
      if error.backup_id
        @backup_anchor = "backup-#{error.backup_id}"
        refresh_link_completion
      end
      render_comparison
    end

    def independent
      authorize ::Library, :index?
      return head :forbidden if ::SiteSettings.demo_mode_enabled?
      return head :not_found unless load_group

      @independent_plan = storage_operations.independent_plan(@left, @right)
      @independent_token = storage_verifier.generate(
        {"context" => storage_context, "fingerprint" => @independent_plan.fingerprint},
        purpose: "make-independent", expires_in: 15.minutes
      )
      render_comparison
    rescue StorageOperations::Error => error
      @storage_error = error.message
      render_comparison
    end

    def make_independent
      authorize ::Library, :index?
      return head :forbidden if ::SiteSettings.demo_mode_enabled?
      return head :not_found unless load_group

      plan = storage_verifier.verified(params[:plan].to_s, purpose: "make-independent")
      unless params[:confirm] == "1" && plan.is_a?(Hash) && plan["context"] == storage_context
        @storage_error = "The plan expired or the comparison changed. Review the independent copy again."
        return render_comparison
      end

      storage_operations.make_independent(@left, @right, digest: @digest, fingerprint: plan.fetch("fingerprint"))
      @storage_feedback = "The right copy now has its own storage."
      @link_complete = false
      render_comparison
    rescue StorageOperations::Error => error
      @storage_error = error.message
      render_comparison
    end

    def backups
      authorize ::Library, :index?
      load_backups
    end

    def restore_copy
      finish_backup(:restore)
    end

    def purge_backup
      finish_backup(:purge)
    end

    def warnings
      authorize ::Library, :index?
      return head :forbidden if ::SiteSettings.demo_mode_enabled?
      return head :not_found unless load_group

      action = params[:warning_action]
      return head :bad_request unless %w[acknowledge reopen].include?(action)

      ignore = action == "acknowledge"
      outcome = ::ModelFile.transaction do
        current = inventory.snapshot(@digest, lock: true)
        next :stale unless current.fingerprint == params[:fingerprint]

        targets = current.copies
        if params.key?(:copy)
          targets = targets.select { |copy| copy.public_id == params[:copy] }
          next :missing if targets.empty?
        end

        warnings = group_warnings(current).where(problematic_id: targets.map(&:id)).order(:id).lock.to_a
        changed = warnings.select { |warning| !warning.in_progress && warning.ignored != ignore }
        changed.each { |warning| authorize warning, :update? }
        changed.each { |warning| warning.update!(ignored: ignore) }

        warned_ids = warnings.map(&:problematic_id).to_set
        review_targets = ignore ? targets.reject { |copy| warned_ids.include?(copy.id) } : targets
        [changed.length, review_targets.map(&:public_id)]
      end
      if outcome == :stale
        return render plain: "The indexed copies changed. Reload this comparison and review them again.", status: :conflict
      end
      return head :not_found if outcome == :missing

      changed, copy_ids = outcome
      @warning_copy = params[:copy]
      load_warning_counts
      save_copy_acknowledgments(action, copy_ids)
      load_saved_review
      if changed.positive? || copy_ids.empty?
        @warning_feedback = ignore ? "Acknowledged #{helpers.pluralize(changed, 'duplicate warning')}." :
          "Reopened #{helpers.pluralize(changed, 'duplicate warning')}."
      end
      render_comparison
    end

    def decision
      authorize ::Library, :index?
      return head :forbidden if ::SiteSettings.demo_mode_enabled?
      return head :not_found unless load_group

      unless params[:fingerprint] == @snapshot.fingerprint
        return head :conflict
      end

      kind = params[:decision]
      return head :bad_request unless %w[prefer keep reviewed later clear].include?(kind)
      copy_id = params[:preferred].presence if %w[prefer reviewed].include?(kind)
      return head :bad_request if copy_id && @snapshot.copies.none? { |copy| copy.public_id == copy_id }
      if kind == "prefer" && !copy_id
        @review_feedback = "Choose a preferred copy first."
        return render_comparison
      end

      review_store.update(@digest, @snapshot.fingerprint) do |state|
        if %w[keep reviewed later].include?(kind)
          copy_id ||= state.dig("decision", "copy")
        end
        state["decision"] = kind == "clear" ? nil : {"type" => kind, "copy" => copy_id}
      end
      load_saved_review
      if kind == "prefer" && params[:preview_links] == "1"
        prepare_group_plan
      elsif kind == "prefer"
        @keeper_updated = copy_id
      end
      render_comparison
    rescue ReviewStore::Error
      @review_feedback = "Manyfold could not save your review. Check the plugin’s review data folder."
      render_comparison
    end

    def import_reviews
      authorize ::Library, :index?
      return head :forbidden if ::SiteSettings.demo_mode_enabled?
      raw = params[:reviews]
      return head :bad_request unless raw.is_a?(String) && raw.bytesize <= 256_000

      entries = JSON.parse(raw)
      return head :bad_request unless entries.is_a?(Array) && entries.size <= 50

      set_filters
      digests = entries.filter_map { |entry| checksum(entry["digest"]) if entry.is_a?(Hash) }.uniq
      snapshots = inventory.snapshots(digests)
      entries.each do |entry|
        next unless entry.is_a?(Hash)

        digest = checksum(entry["digest"])
        snapshot = snapshots[digest]
        next unless snapshot && snapshot.copies.size > 1 && snapshot.fingerprint == entry["fingerprint"]

        ids = snapshot.copies.map(&:public_id)
        copied = Array(entry["copies"]) & ids
        decision = entry["decision"]
        review_store.update(digest, snapshot.fingerprint, import: true) do |state|
          state["copies"] = copied
          if decision.is_a?(Hash) && %w[prefer keep reviewed later].include?(decision["type"])
            state["decision"] = {"type" => decision["type"], "copy" => ids.include?(decision["copy"]) ? decision["copy"] : nil}
          end
        end
      end
      head :no_content
    rescue JSON::ParserError
      head :bad_request
    rescue ReviewStore::Error
      head :service_unavailable
    end

    def theme
      serve_asset("theme.css", "text/css")
    end

    def script
      serve_asset("review.js", "application/javascript")
    end

    private

    def review_store
      @review_store ||= ReviewStore.new(
        ENV.fetch("DUPLICATE_ADJUDICATOR_REVIEW_ROOT") do
          File.join(ENV.fetch("PLUGINS_PATH", Rails.root.join("plugins").to_s), ".duplicate-adjudicator-reviews")
        end, current_user.id
      )
    end

    def saved_review(digest)
      review_store.read(digest)
    rescue ReviewStore::Error
      nil
    end

    def review_import_url
      mounted_url("/review-import")
    end

    def save_copy_acknowledgments(action, copy_ids)
      review_store.update(@digest, @snapshot.fingerprint) do |state|
        if action == "acknowledge"
          state["copies"] |= copy_ids
          saved_count = (@group_copy_progress[:unwarned] & state["copies"]).size
          if state.dig("decision", "type") == "later" && saved_count + @ignored_warnings == @snapshot.copies.size
            preferred = state.dig("decision", "copy")
            state["decision"] = preferred ? {"type" => "prefer", "copy" => preferred} : nil
          end
        else
          state["copies"] -= copy_ids
          if %w[keep reviewed].include?(state.dig("decision", "type"))
            preferred = state.dig("decision", "copy")
            state["decision"] = preferred ? {"type" => "prefer", "copy" => preferred} : nil
          end
        end
      end
    rescue ReviewStore::Error
      @copy_review_error = "Manyfold could not save the copy acknowledgments. Existing Manyfold warnings can be checked on the Problems screen."
    end

    def selected_targets(values)
      return unless values.is_a?(Array) && values.any? && values.size <= @compare_copies.size

      targets = values.uniq.map { |public_id| file_choice(public_id, excluding: @left.id) }
      targets unless targets.any?(&:nil?)
    end

    def prepare_group_plan
      keeper = @records[@preferred_copy&.id]
      if keeper
        copies = @snapshot.copies.reject { |copy| copy.id == keeper.id }
        prepare_batch_plan(copies, keeper: keeper, whole_group: true)
      else
        @storage_error = "Set a keeper on a copy’s card to review the group."
      end
    end

    def prepare_batch_plan(copies, keeper:, whole_group:)
      @restore_root = storage_operations.root
      @batch_keeper = @copy_by_id.fetch(keeper.id)
      @batch_whole_group = whole_group
      records = inventory.records(copies, digest: @digest)
      planned_paths = Set.new
      @batch_preview = copies.map do |copy|
        file = records[copy.id]
        next({copy: copy, status: :blocked, message: "This copy is no longer in the indexed group."}) unless file

        pair = StoragePreview.call(keeper, file)
        if pair.status == :same_file
          next({copy: copy, status: :shared, independent: pair.source_path != pair.target_path})
        end

        plan = storage_operations.plan(keeper, file, pair: pair)
        if !planned_paths.add?(pair.target_path)
          next({copy: copy, status: :alias_path, message: "Another record in this plan uses this same file path."})
        end
        {copy: copy, status: :eligible, plan: plan}
      rescue StorageOperations::Error => error
        {copy: copy, status: :blocked, message: error.message}
      end
      if whole_group
        @link_complete = false
        refresh_link_completion if @batch_preview.all? { |entry| entry[:status] == :shared }
      end
      fingerprints = @batch_preview.filter_map do |entry|
        [entry.fetch(:copy).public_id, entry.fetch(:plan).batch_fingerprint] if entry[:plan]
      end.to_h
      return if fingerprints.empty?

      context = whole_group ? group_storage_context(@batch_keeper) : storage_context
      @batch_token = storage_verifier.generate({"context" => context, "targets" => fingerprints, "group" => whole_group},
        purpose: "link-copies", expires_in: 15.minutes)
    rescue StorageOperations::Error => error
      @storage_error = error.message
    end

    def apply_batch_plan(keeper, copies, fingerprints, acknowledge:)
      @batch_keeper = @copy_by_id.fetch(keeper.id)
      records = inventory.records(copies, digest: @digest)
      @batch_results = copies.map do |copy|
        file = records[copy.id]
        next({copy: copy, status: :failed, message: "This copy is no longer in the indexed group."}) unless file

        pair = StoragePreview.call(keeper, file)
        if pair.status == :same_file
          next({copy: copy, status: :shared, independent: pair.source_path != pair.target_path})
        end

        warning_targets = @snapshot.copies.size == 2 ? [keeper.id, file.id] : [file.id]
        warning_ids = acknowledge ? planned_warning_ids(warning_targets) : []
        id = storage_operations.apply_batch_member(keeper, file, digest: @digest,
          fingerprint: fingerprints.fetch(file.public_id), warnings: warning_ids)
        {copy: copy, status: :linked, id: id, independent: true, message: update_storage_warnings(warning_ids, ignored: true)}
      rescue StorageOperations::Error => error
        {copy: copy, status: error.linked ? :attention : :failed, id: error.backup_id, message: error.message}
      end
      load_warning_counts
    end

    def group_storage_context(keeper)
      [current_user.id.to_s, @digest, keeper.public_id, @snapshot.fingerprint] if keeper
    end

    def prepare_storage_plan
      @restore_root = storage_operations.root
      @storage_plan = storage_operations.plan(@left, @right, pair: @storage)
      @storage_token = storage_verifier.generate(
        {"context" => storage_context, "fingerprint" => @storage_plan.fingerprint},
        purpose: "link-copies", expires_in: 15.minutes
      )
    rescue StorageOperations::Error => error
      @storage_error = error.message
    end

    def storage_context
      [current_user.id.to_s, @digest, @left.public_id, @right.public_id, @snapshot.fingerprint]
    end

    def storage_verifier
      Rails.application.message_verifier("duplicate-adjudicator-storage")
    end

    def storage_operations
      @storage_operations ||= StorageOperations.new(@libraries)
    end

    def planned_warning_ids(ids = @snapshot.copies.size == 2 ? [@left.id, @right.id] : [@right.id])
      problems = group_warnings.where(problematic_id: ids, ignored: false, in_progress: false).to_a
      problems.each { |problem| authorize problem, :update? }
      problems.map(&:id)
    end

    def update_storage_warnings(ids, ignored:)
      return if ids.blank?

      ::Problem.transaction do
        problems = policy_scope(::Problem.including_ignored).where(id: ids, category: :duplicate,
          problematic_type: "ModelFile", ignored: !ignored, in_progress: false).order(:id).lock.to_a
        problems.each { |problem| authorize problem, :update? }
        problems.each { |problem| problem.update!(ignored: ignored) }
      end
      nil
    rescue ActiveRecord::ActiveRecordError, Pundit::NotAuthorizedError
      "The disk operation finished. Update its warnings on the Manyfold Problems screen."
    end

    def load_backups
      @title = "Restore backups"
      @libraries = policy_scope(::Library).to_a
      @restore_root = storage_operations.root
      @batches = storage_operations.batches
      @pending_bytes = storage_operations.pending_bytes(@batches)
      @backup_states = @batches.to_h { |batch| [batch.fetch("id"), storage_operations.state(batch)] }
    rescue StorageOperations::Error => error
      @backup_error = error.message
      @batches = []
    end

    def finish_backup(action)
      authorize ::Library, :index?
      return head :forbidden if ::SiteSettings.demo_mode_enabled?
      return head :bad_request unless params[:confirm] == "1"

      @libraries = policy_scope(::Library).to_a
      batch = storage_operations.read(params[:id])
      return head :not_found unless batch

      file = policy_scope(::ModelFile).where(model_id: policy_scope(::Model).local
        .where(library_id: @libraries.map(&:id)).reorder(nil).select(:id))
        .find_by(public_id: batch.fetch("target_file"))
      already_finished = storage_operations.state(batch) == (action == :restore ? "restored" : "purged")
      result = storage_operations.finish(params[:id], file, action)
      flash[:alert] = update_storage_warnings(result["warnings"], ignored: false) if action == :restore && !already_finished
      flash[:notice] = action == :restore ? "Restored the original file." : "Purged the saved original."
      redirect_to backups_url(anchor: "backup-#{params[:id]}"), status: :see_other
    rescue StorageOperations::Error => error
      load_backups
      @backup_error = error.message
      render :backups, status: :unprocessable_content
    end

    def backups_url(anchor: nil)
      path = mounted_url("/backups")
      anchor ? "#{path}##{anchor}" : path
    end

    def backup_action_url(id, action)
      mounted_url("/backups/#{id}/#{action}")
    end

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
      @sort = params[:sort] == "savings" ? "savings" : nil
      @after = queue_cursor(params[:after])
      @review_view = params[:review] == "all" ? "all" : nil
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
      load_saved_review
      selected_ids = [params[:left], params[:right], @preferred_copy&.public_id]
      selected = @snapshot.copies.select { |copy| selected_ids.include?(copy.public_id) }
      @records = inventory.records((copies + selected).uniq, digest: @digest)
      @copies = copies.select { |copy| @records.key?(copy.id) }
      return false if @copies.empty?

      @left = file_choice(params[:left]) || @records[@preferred_copy&.id] || @records.fetch(@copies.first.id)
      @right = file_choice(params[:right], excluding: @left.id) ||
        @copies.filter_map { |copy| @records[copy.id] }.find { |file| file.id != @left.id }
      # Keep both cards available when the last page has just one copy.
      if @right.nil?
        other = @snapshot.copies.find { |copy| copy.id != @left.id }
        @records.merge!(inventory.records([other], digest: @digest))
        @right = @records[other.id]
      end
      return false unless @right

      @compare_copies = (@copies + [@copy_by_id.fetch(@left.id), @copy_by_id.fetch(@right.id), @preferred_copy].compact).uniq
      models = @records.values.map(&:model).uniq
      @model_file_counts = inventory.model_file_counts(models.map(&:id))
      collection_ids = models.flat_map { |model| model.collections.map(&:id) }.uniq
      visible_collections = policy_scope(::Collection).where(id: collection_ids).index_by(&:id)
      @collections_by_model = models.to_h do |model|
        [model.id, model.collections.filter_map { |collection| visible_collections[collection.id] }]
      end
      load_warning_counts
      unless inline?
        sizes = @snapshot.copies.map(&:size)
        cursor = @sort == "savings" ? "#{sizes.sum - sizes.max}-#{@digest}" : @digest
        @next_group = inventory.groups(library_id: @library&.id, search: @search, after: cursor, sort: @sort, limit: 1).first
      end
      true
    end

    def duplicate_warnings
      policy_scope(::Problem.including_ignored).where(category: :duplicate, problematic_type: "ModelFile")
    end

    def group_warnings(snapshot = @snapshot)
      duplicate_warnings.where(problematic_id: snapshot.copies.map(&:id))
    end

    def load_queue_review
      @queue_snapshots = inventory.snapshots(@groups.map(&:digest))
      copy_ids = @queue_snapshots.values.flat_map { |snapshot| snapshot.copies.map(&:id) }
      states = warning_states(duplicate_warnings.where(problematic_id: copy_ids))
      @queue_saved_reviews = @queue_snapshots.keys.to_h { |digest| [digest, saved_review(digest)] }
      @queue_copy_progress = @queue_snapshots.transform_values { |snapshot| copy_progress(snapshot, states) }
      @queue_review = @queue_snapshots.to_h do |digest, snapshot|
        progress = @queue_copy_progress.fetch(digest)
        complete = progress[:acknowledged].positive? && progress[:acknowledged] == progress[:total]
        [digest, review_label_for(digest, snapshot, complete)]
      end
    end

    def warning_states(scope)
      scope.pluck(:problematic_id, :ignored, :in_progress).to_h do |id, ignored, in_progress|
        state = if in_progress
          "in_progress"
        elsif ignored
          "acknowledged"
        else
          "open"
        end
        [id, state]
      end
    end

    def copy_progress(snapshot, states)
      {
        total: snapshot.copies.size,
        acknowledged: snapshot.copies.count { |copy| states[copy.id] == "acknowledged" },
        open: snapshot.copies.count { |copy| states[copy.id] == "open" },
        unwarned: snapshot.copies.reject { |copy| states.key?(copy.id) }.map(&:public_id)
      }
    end

    def review_label_for(digest, snapshot, acknowledged)
      if linked_group_digests.include?(digest) && StoragePreview.all_linked?(snapshot.copies, libraries_by_id)
        "All copies linked"
      elsif acknowledged
        "Warnings acknowledged"
      end
    end

    def linked_group_digests
      @linked_group_digests ||= storage_operations.batches
        .reject { |batch| batch["state"] == "restored" }.map { |batch| batch.fetch("digest") }.to_set
    rescue StorageOperations::Error
      @linked_group_digests = Set.new
    end

    def libraries_by_id
      @libraries_by_id ||= @libraries.index_by(&:id)
    end

    def load_warning_counts
      @warning_states = warning_states(group_warnings)
      counts = @warning_states.values.tally
      @ignored_warnings = counts.fetch("acknowledged", 0)
      @group_copy_progress = copy_progress(@snapshot, @warning_states)
    end

    def inline?
      params[:inline] == "1"
    end

    def load_saved_review
      @saved_review = saved_review(@digest)
      @preferred_copy = nil
      if @saved_review && @saved_review["fingerprint"] == @snapshot.fingerprint
        preferred = @saved_review.dig("decision", "copy")
        @preferred_copy = @snapshot.copies.find { |copy| copy.public_id == preferred } if preferred
      end
    end

    def refresh_link_completion
      @link_complete = StoragePreview.all_linked?(@snapshot.copies, libraries_by_id)
    end

    def render_comparison
      @group_review_label = if @link_complete
        "All copies linked"
      elsif @ignored_warnings == @snapshot.copies.size
        "Warnings acknowledged"
      end
      @can_make_independent = !::SiteSettings.demo_mode_enabled? &&
        @storage&.status == :same_file && @storage.source_path != @storage.target_path

      if inline?
        render partial: "comparison", layout: false
      else
        render :show
      end
    end

    def file_choice(public_id, excluding: nil)
      @records.values.find { |file| file.public_id == public_id && file.id != excluding }
    end

    def checksum(value)
      value if value.is_a?(String) && Index::SHA512.match?(value)
    end

    def queue_cursor(value)
      return checksum(value) unless @sort == "savings"

      value if value.is_a?(String) && /\A[0-9]{1,24}-[0-9a-f]{128}\z/.match?(value)
    end

    def filter_params
      {library: @library&.public_id, q: @search.presence, after: @after, review: @review_view, sort: @sort}
    end

    def queue_url(**options)
      mounted_url("/", **filter_params.merge(options))
    end

    def group_url(digest = @digest, **options)
      mounted_url("/group/#{digest}", **filter_params.merge(options))
    end

    def verify_url
      group_action_url("verify")
    end

    def group_action_url(action, **options)
      mounted_url("/group/#{@digest}/#{action}", **filter_params.merge(copies: @page,
        left: @left.public_id, right: @right.public_id).merge(options))
    end

    def copy_label(copy)
      "#{libraries_by_id.fetch(copy.library_id).name} / #{copy.indexed_path}"
    end

    def asset_url(name)
      mounted_url("/#{name}", v: VERSION)
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
