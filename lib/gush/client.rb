require 'connection_pool'

module Gush
  class Client
    attr_reader :configuration

    def initialize(config = Gush.configuration)
      @configuration = config
    end

    def configure
      yield configuration
    end

    def create_workflow(name)
      begin
        name.constantize.create
      rescue NameError
        raise WorkflowNotFound.new("Workflow with given name doesn't exist")
      end
      flow
    end

    def start_workflow(workflow, job_names = [])
      workflow.mark_as_started
      persist_workflow(workflow)

      jobs = if job_names.empty?
               workflow.initial_jobs
             else
               job_names.map {|name| workflow.find_job(name) }
             end

      jobs.each do |job|
        enqueue_job(workflow.id, job)
      end
    end

    def stop_workflow(id)
      workflow = find_workflow(id)
      workflow.mark_as_stopped
      persist_workflow(workflow)
    end

    def next_free_job_id(workflow_id,job_klass)
      job_identifier = nil
      loop do
        id = SecureRandom.uuid
        job_identifier = "#{job_klass}-#{id}"
        available = connection_pool.with do |redis|
          !redis.exists("gush.jobs.#{workflow_id}.#{job_identifier}")
        end

        break if available
      end

      job_identifier
    end

    def next_free_workflow_id
      id = nil
      loop do
        id = SecureRandom.uuid
        available = connection_pool.with do |redis|
          !redis.exists("gush.workflow.#{id}")
        end

        break if available
      end

      id
    end

    def all_workflows(limit=nil, offset=0)
      raw_workflows = connection_pool.with do |redis|
        redis.scan_each(match: "gush.workflows.*").map do |key|
          Gush::JSON.decode(redis.get(key), symbolize_keys: true)
        end
      end
      limit ||= raw_workflows.size
      raw_workflows.sort_by { |w| -w[:created_at] }[offset, limit].map { |w| find_workflow(w[:id]) }
    end

    def all_workflows_size
      connection_pool.with { |redis| redis.scan_each(match: "gush.workflows.*").count }
    end

    def find_workflow(id)
      connection_pool.with do |redis|
        data = redis.get("gush.workflows.#{id}")

        unless data.nil?
          hash = Gush::JSON.decode(data, symbolize_keys: true)
          keys = redis.scan_each(match: "gush.jobs.#{id}.*")
          nodes = redis.mget(*keys).map { |json| Gush::JSON.decode(json, symbolize_keys: true) }
          workflow_from_hash(hash, nodes)
        else
          raise WorkflowNotFound.new("Workflow with given id doesn't exist")
        end
      end
    end

    def persist_workflow(workflow)
      connection_pool.with do |redis|
        redis.set("gush.workflows.#{workflow.id}", workflow.to_json)
      end

      workflow.jobs.each {|job| persist_job(workflow.id, job) }
      workflow.mark_as_persisted
      true
    end

    def persist_job(workflow_id, job)
      connection_pool.with do |redis|
        redis.set("gush.jobs.#{workflow_id}.#{job.name}", job.to_json)
      end
    end

    def find_job(workflow_id, job_id)
      job_name_match = /(?<klass>\w*[^-])-(?<identifier>.*)/.match(job_id)
      hypen = '-' if job_name_match.nil?

      keys = connection_pool.with do |redis|
        redis.scan_each(match: "gush.jobs.#{workflow_id}.#{job_id}#{hypen}*").to_a
      end

      return nil if keys.nil?

      data = connection_pool.with do |redis|
        redis.get(keys.first)
      end

      return nil if data.nil?

      data = Gush::JSON.decode(data, symbolize_keys: true)
      Gush::Job.from_hash(data)
    end

    def destroy_workflow(workflow)
      connection_pool.with do |redis|
        redis.del("gush.workflows.#{workflow.id}")
      end
      workflow.jobs.each {|job| destroy_job(workflow.id, job) }
    end

    def destroy_job(workflow_id, job)
      connection_pool.with do |redis|
        redis.del("gush.jobs.#{workflow_id}.#{job.name}")
      end
    end

    def expire_workflow(workflow, ttl=nil)
      ttl = ttl || configuration.ttl
      connection_pool.with do |redis|
        redis.expire("gush.workflows.#{workflow.id}", ttl)
      end
      workflow.jobs.each {|job| expire_job(workflow.id, job, ttl) }
    end

    def expire_job(workflow_id, job, ttl=nil)
      ttl = ttl || configuration.ttl
      connection_pool.with do |redis|
        redis.expire("gush.jobs.#{workflow_id}.#{job.name}", ttl)
      end
    end

    def enqueue_job(workflow_id, job)
      job.enqueue!
      persist_job(workflow_id, job)
      init_worker(workflow_id, job)
    end

    # clear the subtree starting from given node and restart the workflow
    def restart_workflow(workflow_id, job_name)
      workflow = find_workflow(workflow_id)
      workflow.mark_as_started
      initial_job = workflow.find_job(job_name)
      initial_job.enqueue!
      workflow.clear_job_children!(initial_job)
      persist_workflow(workflow)
      init_worker(workflow_id, initial_job)
    end

    private

    def workflow_from_hash(hash, nodes = [])
      flow = hash[:klass].constantize.new(*hash[:arguments])
      flow.jobs = []
      flow.stopped = hash.fetch(:stopped, false)
      flow.id = hash[:id]
      flow.created_at = hash[:created_at]

      flow.jobs = nodes.map do |node|
        Gush::Job.from_hash(node)
      end

      flow
    end

    def init_worker(workflow_id, job)
      Sidekiq::Client.push(
        {
          'class' => Gush::Worker,
          'args' => [workflow_id, job.name],
          'queue' => configuration.namespace
        }.merge(job.class.sidekiq_options)
      )
    end

    def build_redis
      Redis.new(url: configuration.redis_url)
    end

    def connection_pool
      @connection_pool ||= ConnectionPool.new(size: configuration.concurrency, timeout: 1) { build_redis }
    end
  end
end
