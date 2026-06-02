# frozen_string_literal: true

module Profiler
  module TestRunner
    class Discovery
      SPEC_GLOB  = "spec/**/*_spec.rb"
      TEST_GLOB  = "test/**/*_test.rb"

      def self.frameworks
        frameworks = []
        frameworks << :rspec    if rspec_available?
        frameworks << :minitest if minitest_available?
        frameworks
      end

      def self.files(framework: nil)
        root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
        result = {}

        globs = case framework&.to_sym
                when :rspec    then [SPEC_GLOB]
                when :minitest then [TEST_GLOB]
                else [SPEC_GLOB, TEST_GLOB]
                end

        globs.each do |glob|
          Dir.glob(File.join(root, glob)).each do |path|
            relative = path.sub("#{root}/", "")
            parts = relative.split("/")
            dir   = parts[0..-2].join("/")
            result[dir] ||= []
            result[dir] << { path: relative, name: parts.last }
          end
        end

        result.map do |dir, files|
          {
            directory: dir,
            files: files.sort_by { |f| f[:name] }
          }
        end.sort_by { |d| d[:directory] }
      end

      def self.rspec_available?
        defined?(RSpec) || Gem.loaded_specs.key?("rspec-core")
      rescue
        false
      end

      def self.minitest_available?
        defined?(Minitest) || Gem.loaded_specs.key?("minitest")
      rescue
        false
      end
    end
  end
end
