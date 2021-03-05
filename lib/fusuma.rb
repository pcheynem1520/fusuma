# frozen_string_literal: true

require_relative './fusuma/version'
require_relative './fusuma/multi_logger'
require_relative './fusuma/config'
require_relative './fusuma/environment'
require_relative './fusuma/device'
require_relative './fusuma/plugin/manager'

# this is top level module
module Fusuma
  # main class
  class Runner
    class << self
      def run(option = {})
        set_trap
        read_options(option)
        instance = new
        ## NOTE: Uncomment following line to measure performance
        # instance.run_with_lineprof
        instance.run
      end

      private

      def set_trap
        Signal.trap('INT') { puts exit } # Trap ^C
        Signal.trap('TERM') { puts exit } # Trap `Kill `
      end

      def read_options(option)
        MultiLogger.instance.debug_mode = option[:verbose]

        load_custom_config(option[:config_path])

        Plugin::Manager.require_base_plugins

        Environment.dump_information
        Kernel.exit(0) if option[:version]

        if option[:list]
          Environment.print_device_list
          Kernel.exit(0)
        end

        # TODO: remove keep_device_from_option from command line options
        Plugin::Filters::LibinputDeviceFilter::KeepDevice.from_option = option[:device]

        Process.daemon if option[:daemon]
      end

      def load_custom_config(config_path = nil)
        Config.custom_path = config_path
      end
    end

    def initialize
      @inputs = Plugin::Inputs::Input.plugins.map(&:new)
      @filters = Plugin::Filters::Filter.plugins.map(&:new)
      @parsers = Plugin::Parsers::Parser.plugins.map(&:new)
      @buffers = Plugin::Buffers::Buffer.plugins.map(&:new)
      @detectors = Plugin::Detectors::Detector.plugins.map(&:new)
      @executors = Plugin::Executors::Executor.plugins.map(&:new)
    end

    def run
      loop { pipeline }
    end

    def pipeline
      event = input || return
      clear_expired_events
      filtered = filter(event) || return
      parsed = parse(filtered) || return
      buffered = buffer(parsed) || return
      detected = detect(buffered) || return
      merged = merge(detected) || return
      execute(merged)
    end

    # For performance monitoring
    def run_with_lineprof(count: 1000)
      require 'rblineprof'
      require 'rblineprof-report'

      profile = lineprof(%r{#{Pathname.new(__FILE__).parent}/.}) do
        count.times { pipeline }
      end
      LineProf.report(profile)
      exit 0
    end

    # @return [Plugin::Events::Event]
    def input
      Plugin::Inputs::Input.select(@inputs)
    end

    # @param [Plugin::Events::Event]
    # @return [Plugin::Events::Event]
    def filter(event)
      event if @filters.any? { |f| f.filter(event) }
    end

    # @param [Plugin::Events::Event]
    # @return [Plugin::Events::Event]
    def parse(event)
      @parsers.reduce(event) { |e, p| p.parse(e) if e }
    end

    # @param [Plugin::Events::Event]
    # @return [Array<Plugin::Buffers::Buffer>]
    # @return [NilClass]
    def buffer(event)
      @buffers.any? { |b| b.buffer(event) } && @buffers
    end

    # @param buffers [Array<Buffer>]
    # @return [Array<Event>]
    def detect(buffers)
      @detectors.each_with_object([]) do |detector, detected|
        if (event = detector.detect(buffers))
          detected << event
        end
      end
    end

    # @param events [Array<Plugin::Events::Event>]
    # @return [Plugin::Events::Event] Event merged all records from arguments
    # @return [NilClass] when event is NOT given
    def merge(events)
      main_events, modifiers = events.partition { |event| event.record.mergable? }
      main_events.sort_by! { |e| e.record.trigger_priority }

      main_events.lazy.map do |main_event|
        Config::Searcher.find_condition do
          main_event.record.merge(records: modifiers.map(&:record))
        end

        main_event
      end.first
    end

    # @param event [Plugin::Events::Event]
    def execute(event)
      return unless event

      # Find executable condition and executor
      condition, executor = Config::Searcher.find_condition do
        execute_key= Config.find_execute_key(event.record.index)
        next unless execute_key

        @executors.find { |e| e.execute_keys.include?(execute_key) && e.executable?(event) }
      end

      return if executor.nil?

      # Check interval and execute
      Config::Searcher.with_condition(condition) do
        executor.enough_interval?(event) &&
          executor.update_interval(event) &&
          executor.execute(event)
      end
    end

    def clear_expired_events
      @buffers.each(&:clear_expired)
    end
  end
end
