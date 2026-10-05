# frozen_string_literal: true

module Profiler
  # What every profile reports as allocated_objects: the number of objects Ruby allocated
  # between two readings. GC.stat has no byte count of allocations (no :total_allocated_size on
  # the supported Rubies), so none is reported.
  #
  # The counter belongs to the process, not to the thread: on a multi-threaded server, or with
  # jobs running alongside, the figure includes what the other threads allocated meanwhile.
  module AllocationCounter
    # The bytes per object that profiles saved by earlier versions multiplied the count by, as
    # `memory`: kept to read them back, and to keep writing that field for older readers.
    LEGACY_BYTES_PER_OBJECT = 40

    module_function

    def current
      GC.stat(:total_allocated_objects)
    end
  end
end
