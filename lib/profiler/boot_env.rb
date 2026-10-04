# frozen_string_literal: true

module Profiler
  # ENV as the shell gave it to the process, captured when the gem is loaded, before
  # EnvOverrideStore#apply! or any override set from the profiler writes into ENV. The test
  # runner builds the environment of the processes it starts from this copy, not from ENV.
  BOOT_ENV = ENV.to_h.freeze unless const_defined?(:BOOT_ENV)
end
