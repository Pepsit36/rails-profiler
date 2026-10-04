# frozen_string_literal: true

require_relative "base_collector"

begin
  require "stackprof"
rescue LoadError
  # stackprof not available — lite mode will fall back to TracePoint without memory tracking
end

module Profiler
  module Collectors
    class FunctionProfilerCollector < BaseCollector
      CallFrame = Struct.new(:name, :file, :line, :started_at, :alloc_before, :memsize_before, :recursive, :children)

      GC_FRAME_NAME = "(garbage collection)"

      THREAD_KEYS = %i[
        fn_profiler_mode fn_profiler_clock fn_profiler_wall_start fn_profiler_cpu_start
        fn_profiler_stack fn_profiler_roots fn_profiler_count fn_profiler_depth
      ].freeze

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
          store_data({
            enabled:    false,
            max_frames: Profiler.function_profiling_max_frames,
            mode:       Profiler.function_profiling_mode,
            clock:      Profiler.function_profiling_clock
          })
          return
        end

        mode  = Profiler.function_profiling_mode
        clock = Profiler.function_profiling_clock
        @subscribed = true
        Thread.current[:fn_profiler_mode]  = mode
        Thread.current[:fn_profiler_clock] = clock

        if mode == "lite" && defined?(StackProf)
          # Always record wall + cpu at request level for the comparison stat
          Thread.current[:fn_profiler_wall_start] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          Thread.current[:fn_profiler_cpu_start]  = Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)

          sp_mode = case clock
                    when "cpu"    then :cpu
                    when "object" then :object
                    else               :wall
                    end
          # false when another request already runs the process-wide sampler: then it is not
          # this collector's to stop on release.
          @stackprof_started = StackProf.start(mode: sp_mode, interval: 1000, raw: true)
        else
          subscribe_tracepoint(mode)
        end
      end

      def collect
        mode  = Thread.current[:fn_profiler_mode]  || Profiler.function_profiling_mode
        clock = Thread.current[:fn_profiler_clock] || Profiler.function_profiling_clock
        Thread.current[:fn_profiler_mode]  = nil
        Thread.current[:fn_profiler_clock] = nil

        if mode == "lite" && defined?(StackProf)
          StackProf.stop
          @stackprof_started = false
          result   = StackProf.results
          wall_ms  = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - (Thread.current[:fn_profiler_wall_start] || 0)) * 1000
          cpu_ms   = (Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID) - (Thread.current[:fn_profiler_cpu_start] || 0)) * 1000
          Thread.current[:fn_profiler_wall_start] = nil
          Thread.current[:fn_profiler_cpu_start]  = nil
          collect_stackprof(result, mode, clock, wall_ms, cpu_ms)
        else
          collect_tracepoint(mode)
        end
      end

      def unsubscribe
        if @stackprof_started
          @stackprof_started = false
          if StackProf.running?
            StackProf.stop
            StackProf.results # discards the samples and frees the sampler's buffers
          end
        end

        @trace&.disable
        @trace = nil

        THREAD_KEYS.each { |key| Thread.current[key] = nil } if @subscribed
        @subscribed = false
      end

      def toolbar_summary
        return { text: "off", color: "gray" } unless Profiler.function_profiling_enabled
        case Profiler.function_profiling_mode
        when "lite" then { text: "sampling on", color: "blue" }
        else             { text: "fn profiling on", color: "purple" }
        end
      end

      private

      # ── StackProf (lite mode) ──────────────────────────────────────────────────

      def collect_stackprof(result, mode, clock, wall_ms, cpu_ms)
        unless result
          store_data({ enabled: true, mode: mode, clock: clock, max_frames: 0,
                       frame_cap_reached: false, total_calls: 0, total_duration: 0,
                       functions: [], root_calls: [] })
          return
        end

        frames_meta   = result[:frames] || {}
        raw           = result[:raw]    || []
        total_samples = [result[:samples] || 0, 1].max
        elapsed_ms    = case clock
                        when "object" then total_samples.to_f
                        when "cpu"    then cpu_ms
                        else               wall_ms
                        end
        app_root      = app_root_path

        # Partition frames: app frames vs GC frame
        # Exclude Ruby meta-frames (<main>, <class:Foo>, #<Class:0x...> generated templates) — noise
        gc_frame_ids  = frames_meta.each_with_object(Set.new) { |(id, f), s| s << id if f[:name] == GC_FRAME_NAME }
        app_frame_ids = frames_meta.each_with_object(Set.new) do |(id, f), s|
          s << id if f[:file]&.start_with?(app_root) && !f[:name].to_s.match?(/\A[<#]/)
        end

        gc_samples, gc_overhead_pct = count_gc_samples(raw, gc_frame_ids, total_samples)

        roots = build_sampling_tree(raw, frames_meta, app_frame_ids, total_samples, elapsed_ms)

        functions = frames_meta.filter_map do |id, frame|
          next unless app_frame_ids.include?(id)
          next if frame[:name].to_s.match?(/\A[<#]/)
          total_dur = (frame[:total_samples].to_f / total_samples) * elapsed_ms
          self_dur  = (frame[:samples].to_f      / total_samples) * elapsed_ms
          {
            name:              frame[:name] || id.to_s,
            file:              relative_path(frame[:file] || ""),
            line:              frame[:line] || 0,
            calls:             frame[:total_samples] || 0,
            recursive_calls:   0,
            total_duration:    total_dur.round(3),
            self_duration:     self_dur.round(3),
            allocated_objects: 0,
            memory_bytes:      0,
            self_memory_bytes: 0
          }
        end.sort_by { |f| -f[:total_duration] }

        # For wall/cpu clocks, total_duration = stackprof elapsed (accurate).
        # For object clock, total_duration = total allocations count.
        total_duration = clock == "object" ? total_samples.to_f : elapsed_ms

        store_data({
          enabled:                 true,
          mode:                    mode,
          clock:                   clock,
          elapsed_wall_ms:         wall_ms.round(2),
          elapsed_cpu_ms:          cpu_ms.round(2),
          gc_samples:              gc_samples,
          gc_overhead_pct:         gc_overhead_pct,
          max_frames:              total_samples,
          frame_cap_reached:       false,
          total_calls:             functions.sum { |f| f[:calls] },
          total_duration:          total_duration.round(2),
          total_allocated_objects: 0,
          total_memory_bytes:      0,
          functions:               functions,
          root_calls:              roots.map { |n| serialize_node(n) }
        })
      end

      # Count samples that contain at least one GC frame.
      def count_gc_samples(raw, gc_frame_ids, total_samples)
        return [0, 0.0] if gc_frame_ids.empty?

        gc_count = 0
        i = 0
        while i < raw.length
          depth = raw[i]
          break if i + depth + 1 >= raw.length
          stack = raw[i + 1, depth]
          count = raw[i + depth + 1]
          i += depth + 2
          gc_count += count if stack.any? { |id| gc_frame_ids.include?(id) }
        end

        pct = (gc_count.to_f / total_samples * 100).round(1)
        [gc_count, pct]
      end

      # Parse stackprof raw samples and build a call tree filtered to app/ frames.
      #
      # Raw format: [depth, frame[0]=outermost(caller), ..., frame[depth-1]=innermost(callee), count, ...]
      # frames are already outermost-first, so no reversal needed.
      def build_sampling_tree(raw, frames_meta, app_frame_ids, total_samples, elapsed_ms)
        tree = {}

        i = 0
        while i < raw.length
          depth = raw[i]
          break if i + depth + 1 >= raw.length
          stack = raw[i + 1, depth]
          count = raw[i + depth + 1]
          i += depth + 2

          app_stack = stack.select { |id| app_frame_ids.include?(id) }
          next if app_stack.empty?

          current = tree
          app_stack.each do |frame_id|
            current[frame_id] ||= { samples: 0, children: {} }
            current[frame_id][:samples] += count
            current = current[frame_id][:children]
          end
        end

        nodes_from_sampling_tree(tree, frames_meta, total_samples, elapsed_ms, 0.0)
      end

      def nodes_from_sampling_tree(tree_hash, frames_meta, total_samples, elapsed_ms, parent_offset)
        nodes = []
        cursor = parent_offset

        tree_hash.each do |frame_id, node|
          meta     = frames_meta[frame_id] || {}
          duration = (node[:samples].to_f / total_samples) * elapsed_ms
          children = nodes_from_sampling_tree(node[:children], frames_meta, total_samples, elapsed_ms, cursor)

          nodes << {
            name:        meta[:name] || frame_id.to_s,
            started_at:  cursor / 1000.0,
            finished_at: (cursor + duration) / 1000.0,
            duration:    duration.round(3),
            category:    "method",
            payload: {
              file:              relative_path(meta[:file] || ""),
              line:              meta[:line] || 0,
              allocated_objects: 0,
              memory_bytes:      0,
              recursive:         false,
              samples:           node[:samples]
            },
            children: children
          }
          cursor += duration
        end

        nodes
      end

      # ── TracePoint (full mode) ────────────────────────────────────────────────

      def subscribe_tracepoint(mode)
        app_root   = app_root_path
        max_frames = Profiler.function_profiling_max_frames

        Thread.current[:fn_profiler_stack] = []
        Thread.current[:fn_profiler_roots] = []
        Thread.current[:fn_profiler_count] = 0
        Thread.current[:fn_profiler_depth] = Hash.new(0)

        @trace = TracePoint.new(:call, :return) do |tp|
          next unless tp.path&.start_with?(app_root)

          stack = Thread.current[:fn_profiler_stack]
          next unless stack

          case tp.event
          when :call
            count = (Thread.current[:fn_profiler_count] += 1)
            next if count > max_frames

            fn_name      = "#{tp.defined_class}##{tp.method_id}"
            depth_map    = Thread.current[:fn_profiler_depth]
            is_recursive = (depth_map[fn_name] += 1) > 1

            stack.push(CallFrame.new(
              fn_name,
              relative_path(tp.path),
              tp.lineno,
              Process.clock_gettime(Process::CLOCK_MONOTONIC),
              GC.stat[:total_allocated_objects],
              GC.stat[:oldmalloc_increase_bytes],
              is_recursive,
              []
            ))
          when :return
            frame = stack.pop
            next unless frame

            Thread.current[:fn_profiler_depth][frame.name] -= 1
            finished_at  = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            allocated    = GC.stat[:total_allocated_objects] - frame.alloc_before
            memory_bytes = [GC.stat[:oldmalloc_increase_bytes] - frame.memsize_before, 0].max
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

      def collect_tracepoint(mode)
        @trace&.disable
        @trace = nil

        stack      = Thread.current[:fn_profiler_stack]
        roots      = Thread.current[:fn_profiler_roots] || []
        count      = Thread.current[:fn_profiler_count] || 0
        max_frames = Profiler.function_profiling_max_frames

        if stack&.any?
          finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          until stack.empty?
            frame        = stack.pop
            allocated    = GC.stat[:total_allocated_objects] - frame.alloc_before
            memory_bytes = [GC.stat[:oldmalloc_increase_bytes] - frame.memsize_before, 0].max
            node = build_node(frame, finished_at, allocated, memory_bytes)
            if stack.empty?
              roots << node
            else
              stack.last.children << node
            end
          end
        end

        Thread.current[:fn_profiler_stack] = nil
        Thread.current[:fn_profiler_roots] = nil
        Thread.current[:fn_profiler_count] = nil
        Thread.current[:fn_profiler_depth] = nil

        stats = {}
        aggregate(roots, stats)
        sorted_functions = stats.values.sort_by { |s| -s[:total_duration] }

        total_duration  = roots.sum { |n| n[:duration] }
        total_allocated = stats.values.sum { |s| s[:allocated_objects] }
        total_memory    = stats.values.sum { |s| s[:memory_bytes] }

        store_data({
          enabled:                 true,
          mode:                    mode,
          clock:                   "wall",
          elapsed_wall_ms:         total_duration.round(2),
          elapsed_cpu_ms:          nil,
          gc_samples:              0,
          gc_overhead_pct:         0.0,
          max_frames:              max_frames,
          frame_cap_reached:       count >= max_frames,
          total_calls:             stats.values.sum { |s| s[:calls] },
          total_duration:          total_duration.round(2),
          total_allocated_objects: total_allocated,
          total_memory_bytes:      total_memory,
          functions: sorted_functions.map do |s|
            s.merge(
              total_duration:    s[:total_duration].round(3),
              self_duration:     s[:self_duration].round(3),
              memory_bytes:      s[:memory_bytes],
              self_memory_bytes: s[:self_memory_bytes]
            )
          end,
          root_calls: roots.map { |n| serialize_node(n) }
        })
      end

      # ── Shared helpers ─────────────────────────────────────────────────────────

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
