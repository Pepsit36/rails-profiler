# frozen_string_literal: true

require_relative "base_collector"
require "objspace"

module Profiler
  module Collectors
    class FunctionProfilerCollector < BaseCollector
      CallFrame = Struct.new(:name, :file, :line, :started_at, :alloc_before, :memsize_before, :recursive, :children)

      def name
        "function_profile"
      end

      def icon
        "⚡"
      end

      def priority
        31
      end

      def tab_config
        {
          key: "function_profile",
          label: "Function Profile",
          icon: icon,
          priority: priority,
          enabled: false,
          default_active: false
        }
      end

      def has_data?
        false
      end

      def subscribe
        unless Profiler.function_profiling_enabled
          store_data({ enabled: false, max_frames: Profiler.function_profiling_max_frames })
          return
        end

        app_root = app_root_path
        max_frames = Profiler.function_profiling_max_frames
        Thread.current[:fn_profiler_stack] = []
        Thread.current[:fn_profiler_roots] = []
        Thread.current[:fn_profiler_count] = 0

        @trace = TracePoint.new(:call, :return) do |tp|
          next unless tp.path&.start_with?(app_root)

          stack = Thread.current[:fn_profiler_stack]
          next unless stack

          case tp.event
          when :call
            count = (Thread.current[:fn_profiler_count] += 1)
            next if count > max_frames

            fn_name = "#{tp.defined_class}##{tp.method_id}"
            is_recursive = stack.any? { |f| f.name == fn_name }

            stack.push(CallFrame.new(
              fn_name,
              relative_path(tp.path),
              tp.lineno,
              Process.clock_gettime(Process::CLOCK_MONOTONIC),
              GC.stat[:total_allocated_objects],
              ObjectSpace.memsize_of_all,
              is_recursive,
              []
            ))
          when :return
            frame = stack.pop
            next unless frame

            finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            allocated    = GC.stat[:total_allocated_objects] - frame.alloc_before
            memory_bytes = [ObjectSpace.memsize_of_all - frame.memsize_before, 0].max
            node = build_node(frame, finished_at, allocated, memory_bytes)

            if stack.empty?
              Thread.current[:fn_profiler_roots] << node
            else
              stack.last.children << node
            end
          end
        end

        @trace.enable
      end

      def collect
        @trace&.disable
        @trace = nil

        stack  = Thread.current[:fn_profiler_stack]
        roots  = Thread.current[:fn_profiler_roots] || []
        count  = Thread.current[:fn_profiler_count] || 0
        max_frames = Profiler.function_profiling_max_frames

        # Flush any frames still on the stack (e.g. if an exception was raised)
        if stack&.any?
          finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          until stack.empty?
            frame        = stack.pop
            allocated    = GC.stat[:total_allocated_objects] - frame.alloc_before
            memory_bytes = [ObjectSpace.memsize_of_all - frame.memsize_before, 0].max
            node = build_node(frame, finished_at, allocated, memory_bytes)
            if stack.empty?
              roots << node
            else
              stack.last.children << node
            end
          end
        end

        Thread.current[:fn_profiler_stack]  = nil
        Thread.current[:fn_profiler_roots]  = nil
        Thread.current[:fn_profiler_count]  = nil

        stats = {}
        aggregate(roots, stats)
        sorted_functions = stats.values.sort_by { |s| -s[:total_duration] }

        total_duration    = roots.sum { |n| n[:duration] }
        total_allocated   = stats.values.sum { |s| s[:allocated_objects] }
        total_memory      = stats.values.sum { |s| s[:memory_bytes] }

        store_data({
          enabled:           true,
          max_frames:        max_frames,
          frame_cap_reached: count >= max_frames,
          total_calls:       stats.values.sum { |s| s[:calls] },
          total_duration:    total_duration.round(2),
          total_allocated_objects: total_allocated,
          total_memory_bytes: total_memory,
          functions: sorted_functions.map do |s|
            s.merge(
              total_duration:  s[:total_duration].round(3),
              self_duration:   s[:self_duration].round(3),
              memory_bytes:    s[:memory_bytes],
              self_memory_bytes: s[:self_memory_bytes]
            )
          end,
          root_calls: roots.map { |n| serialize_node(n) }
        })
      end

      def toolbar_summary
        return { text: "off", color: "gray" } unless Profiler.function_profiling_enabled
        { text: "fn profiling on", color: "purple" }
      end

      private

      def app_root_path
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join("app").to_s
        else
          File.join(Dir.pwd, "app")
        end
      end

      def relative_path(path)
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          path.delete_prefix(Rails.root.to_s + "/")
        else
          path.delete_prefix(Dir.pwd + "/")
        end
      end

      def build_node(frame, finished_at, allocated, memory_bytes)
        {
          name:        frame.name,
          started_at:  frame.started_at,
          finished_at: finished_at,
          duration:    ((finished_at - frame.started_at) * 1000).round(3),
          category:    "method",
          payload: {
            file:              frame.file,
            line:              frame.line,
            allocated_objects: allocated,
            memory_bytes:      memory_bytes,
            recursive:         frame.recursive
          },
          children: frame.children
        }
      end

      def serialize_node(node)
        node.merge(children: node[:children].map { |c| serialize_node(c) })
      end

      def aggregate(nodes, stats)
        nodes.each do |node|
          key = "#{node[:name]}|#{node[:payload][:file]}:#{node[:payload][:line]}"
          stats[key] ||= {
            name:              node[:name],
            file:              node[:payload][:file],
            line:              node[:payload][:line],
            calls:             0,
            recursive_calls:   0,
            total_duration:    0.0,
            self_duration:     0.0,
            allocated_objects: 0,
            memory_bytes:      0,
            self_memory_bytes: 0
          }
          s = stats[key]
          s[:calls]             += 1
          s[:recursive_calls]   += 1 if node[:payload][:recursive]
          s[:total_duration]    += node[:duration]
          s[:allocated_objects] += node[:payload][:allocated_objects]
          s[:memory_bytes]      += node[:payload][:memory_bytes]

          children_duration = node[:children].sum { |c| c[:duration] }
          children_memory   = node[:children].sum { |c| c[:payload][:memory_bytes] }
          s[:self_duration]     += (node[:duration] - children_duration)
          s[:self_memory_bytes] += (node[:payload][:memory_bytes] - children_memory)

          aggregate(node[:children], stats)
        end
      end
    end
  end
end
