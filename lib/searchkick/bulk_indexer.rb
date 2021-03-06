module Searchkick
  class BulkIndexer
    attr_reader :index

    def initialize(index)
      @index = index
    end

    def import_scope(scope, resume: false, method_name: nil, async: false, batch: false, batch_id: nil, full: false)
      # use scope for import
      scope = scope.search_import if scope.respond_to?(:search_import)

      if batch
        import_or_update scope.to_a, method_name, async
        Searchkick.with_redis { |r| r.srem(batches_key, batch_id) } if batch_id
      elsif full && async
        full_reindex_async(scope)
      elsif scope.respond_to?(:find_in_batches)
        if resume
          # use total docs instead of max id since there's not a great way
          # to get the max _id without scripting since it's a string

          # TODO use primary key and prefix with table name
          scope = scope.where("id > ?", total_docs)
        end

        scope = scope.select("id").except(:includes, :preload) if async

        scope.find_in_batches batch_size: batch_size do |items|
          import_or_update items, method_name, async
        end
      else
        each_batch(scope) do |items|
          import_or_update items, method_name, async
        end
      end
    end

    def bulk_index(records)
      Searchkick.indexer.queue(records.map { |r| RecordData.new(index, r).index_data })
    end

    def bulk_delete(records)
      Searchkick.indexer.queue(records.reject { |r| r.id.blank? }.map { |r| RecordData.new(index, r).delete_data })
    end

    def bulk_update(records, method_name)
      Searchkick.indexer.queue(records.map { |r| RecordData.new(index, r).update_data(method_name) })
    end

    private

    def import_or_update(records, method_name, async)
      if records.any?
        if async
          Searchkick::BulkReindexJob.perform_later(
            class_name: records.first.class.name,
            record_ids: records.map(&:id),
            index_name: index.name,
            method_name: method_name ? method_name.to_s : nil
          )
        else
          records = records.select(&:should_index?)
          if records.any?
            with_retries do
              # call out to index for ActiveSupport notifications
              if method_name
                index.bulk_update(records, method_name)
              else
                index.bulk_index(records)
              end
            end
          end
        end
      end
    end

    def full_reindex_async(scope)
      if scope.respond_to?(:primary_key)
        # TODO expire Redis key
        primary_key = scope.primary_key

        starting_id =
          begin
            scope.minimum(primary_key)
          rescue ActiveRecord::StatementInvalid
            false
          end

        if starting_id.nil?
          # no records, do nothing
        elsif starting_id.is_a?(Numeric)
          max_id = scope.maximum(primary_key)
          batches_count = ((max_id - starting_id + 1) / batch_size.to_f).ceil

          batches_count.times do |i|
            batch_id = i + 1
            min_id = starting_id + (i * batch_size)
            bulk_reindex_job scope, batch_id, min_id: min_id, max_id: min_id + batch_size - 1
          end
        else
          scope.find_in_batches(batch_size: batch_size).each_with_index do |batch, i|
            batch_id = i + 1

            bulk_reindex_job scope, batch_id, record_ids: batch.map { |record| record.id.to_s }
          end
        end
      else
        batch_id = 1
        # TODO remove any eager loading
        scope = scope.only(:_id) if scope.respond_to?(:only)
        each_batch(scope) do |items|
          bulk_reindex_job scope, batch_id, record_ids: items.map { |i| i.id.to_s }
          batch_id += 1
        end
      end
    end

    def each_batch(scope)
      # https://github.com/karmi/tire/blob/master/lib/tire/model/import.rb
      # use cursor for Mongoid
      items = []
      scope.all.each do |item|
        items << item
        if items.length == batch_size
          yield items
          items = []
        end
      end
      yield items if items.any?
    end

    def bulk_reindex_job(scope, batch_id, options)
      Searchkick::BulkReindexJob.perform_later({
        class_name: scope.model_name.name,
        index_name: index.name,
        batch_id: batch_id
      }.merge(options))
      Searchkick.with_redis { |r| r.sadd(batches_key, batch_id) }
    end

    def with_retries
      retries = 0

      begin
        yield
      rescue Faraday::ClientError => e
        if retries < 1
          retries += 1
          retry
        end
        raise e
      end
    end

    def batches_left
      Searchkick.with_redis { |r| r.scard(batches_key) }
    end

    def batches_key
      "searchkick:reindex:#{index.name}:batches"
    end

    def batch_size
      @batch_size ||= index.options[:batch_size] || 1000
    end
  end
end
