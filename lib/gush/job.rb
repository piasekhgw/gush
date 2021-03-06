module Gush
  class Job
    class Error < StandardError; end
    class SoftFail < Error; end
    class LoopFail < Error; end

    attr_accessor :workflow_id, :incoming, :outgoing, :params,
      :finished_at, :failed_at, :started_at, :enqueued_at, :payloads, :klass, :soft_fail
    attr_reader :name, :output_payload, :params

    def self.sidekiq_options
      {}
    end

    def self.default_sidekiq_options
      { 'retry' => false }
    end

    def self.full_sidekiq_options
      default_sidekiq_options.merge(sidekiq_options)
    end

    def initialize(opts = {})
      options = opts.dup
      assign_variables(options)
    end

    def as_json
      {
        name: name,
        klass: self.class.to_s,
        incoming: incoming,
        outgoing: outgoing,
        finished_at: finished_at,
        enqueued_at: enqueued_at,
        started_at: started_at,
        failed_at: failed_at,
        params: params,
        workflow_id: workflow_id,
        output_payload: output_payload,
        soft_fail: soft_fail
      }
    end

    def to_json(options = {})
      Gush::JSON.encode(as_json)
    end

    def self.from_hash(hash)
      hash[:klass].constantize.new(hash)
    end

    def output(data)
      @output_payload = data
    end

    def perform
    end

    def start!
      @started_at = current_timestamp
    end

    def enqueue!
      @enqueued_at = current_timestamp
      @started_at = nil
      @finished_at = nil
      @failed_at = nil
      @soft_fail = nil
    end

    def finish!
      @finished_at = current_timestamp
    end

    def fail!(soft_fail=false)
      @finished_at = @failed_at = current_timestamp
      @soft_fail = soft_fail
    end

    def clear!
      @enqueued_at = nil
      @started_at = nil
      @finished_at = nil
      @failed_at = nil
      @soft_fail = nil
    end

    def enqueued?
      !enqueued_at.nil?
    end

    def finished?
      !finished_at.nil?
    end

    def failed?
      !failed_at.nil?
    end

    def failed_softly?
      failed? && soft_fail
    end

    def succeeded?
      finished? && !failed?
    end

    def started?
      !started_at.nil?
    end

    def running?
      started? && !finished?
    end

    def ready_to_start?
      !running? && !enqueued? && !finished? && !failed? && parents_succeeded?
    end

    def parents_succeeded?
      !incoming.any? do |name|
        !client.find_job(workflow_id, name).succeeded?
      end
    end

    def has_no_dependencies?
      incoming.empty?
    end

    def loop_opts
      params[:loop_opts]
    end

    def expired?
      return false if loop_opts.nil?
      Time.now > Time.at(loop_opts[:end_time])
    end

    def no_retries?
      !self.class.full_sidekiq_options['retry']
    end

    private

    def client
      @client ||= Client.new
    end

    def current_timestamp
      Time.now.to_i
    end

    def assign_variables(opts)
      @name           = opts[:name]
      @incoming       = opts[:incoming] || []
      @outgoing       = opts[:outgoing] || []
      @failed_at      = opts[:failed_at]
      @finished_at    = opts[:finished_at]
      @started_at     = opts[:started_at]
      @enqueued_at    = opts[:enqueued_at]
      @params         = opts[:params] || {}
      @klass          = opts[:klass]
      @output_payload = opts[:output_payload]
      @workflow_id    = opts[:workflow_id]
      @soft_fail      = opts[:soft_fail]
    end
  end
end
