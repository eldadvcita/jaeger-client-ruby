# frozen_string_literal: true

require 'thread'

module Jaeger
  module Client
    class Collector
      def initialize
        @buffer = Buffer.new
      end

      def send_span(span, end_time)
        context = span.context
        start_ts, duration = build_timestamps(span, end_time)
        return if !context.sampled? && !context.debug?

        log("ThriftSender: Collector @send_span: Collector.object_id: #{self.object_id}, @buffer: #{@buffer.object_id}, length: #{@buffer.length}")

        @buffer << Jaeger::Thrift::Span.new(
          'traceIdLow' => context.trace_id,
          'traceIdHigh' => 0,
          'spanId' => context.span_id,
          'parentSpanId' => context.parent_id,
          'operationName' => span.operation_name,
          'references' => build_references(span.references || []),
          'flags' => context.flags,
          'startTime' => start_ts,
          'duration' => duration,
          'tags' => span.tags,
          'logs' => span.logs
        )
      end

      def retrieve(limit = nil)
        @buffer.retrieve(limit)
      end

      def length
        @buffer.length
      end

      def buffer
        @buffer
      end

      private
      def log(msg)
        if Rails && Rails.logger.present?
          Rails.logger.error(msg)
        else
          puts msg
        end
      end

      def build_references(references)
        references.map do |ref|
          Jaeger::Thrift::SpanRef.new(
            'refType' => span_ref_type(ref.type),
            'traceIdLow' => ref.context.trace_id,
            'traceIdHigh' => 0,
            'spanId' => ref.context.span_id
          )
        end
      end

      def build_timestamps(span, end_time)
        start_ts = (span.start_time.to_f * 1_000_000).to_i
        end_ts = (end_time.to_f * 1_000_000).to_i
        duration = end_ts - start_ts
        [start_ts, duration]
      end

      def span_ref_type(type)
        case type
        when OpenTracing::Reference::CHILD_OF
          Jaeger::Thrift::SpanRefType::CHILD_OF
        when OpenTracing::Reference::FOLLOWS_FROM
          Jaeger::Thrift::SpanRefType::FOLLOWS_FROM
        else
          warn "Jaeger::Client with format #{type} is not supported yet"
          nil
        end
      end

      # https://vaneyckt.io/posts/ruby_concurrency_in_praise_of_condition_variables/
      class Buffer
        def initialize
          @buffer = []
          @mutex = Mutex.new
          @cond_var = ConditionVariable.new
        end

        def <<(element)
          @mutex.synchronize do
            @buffer << element
            log("ThriftSender: Buffer: << element #{length} + Signaling, @mutex: #{@mutex.object_id}, @@cond_var: #{@cond_var.object_id}")
            @cond_var.signal
            true
          end
        end

        def length
          @buffer.length
        end

        def retrieve(limit = nil, blocking = true)
          @mutex.synchronize do
            log("ThriftSender: Buffer: retrieve element limit #{limit || @buffer.length}, @mutex: #{@mutex.object_id}, @@cond_var: #{@cond_var.object_id}, waiting for signal")
            if blocking
              while @buffer.empty?
                @cond_var.wait(@mutex)
                log("ThriftSender: Buffer: retrieve element limit #{limit || @buffer.length}, waiting for signal - Spurious wakeup") if @buffer.empty?
              end
            end
            log("ThriftSender: Buffer: SIGNAL received")

            @buffer.shift(limit || @buffer.length)
          end
        end

        private
        def log(msg)
          if Rails && Rails.logger.present?
            Rails.logger.error(msg)
          else
            puts msg
          end
        end
      end
    end
  end
end
