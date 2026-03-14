# frozen_string_literal: true

require_relative "lib/profiler/version"

Gem::Specification.new do |spec|
  spec.name = "profiler"
  spec.version = Profiler::VERSION
  spec.authors = ["Rails Profiler Team"]
  spec.email = ["profiler@example.com"]

  spec.summary = "Rails profile"
  spec.description = "A comprehensive Rails profiler with web debug toolbar, profiling UI, SQL analysis, performance timeline, and MCP server integration"
  spec.homepage = "https://github.com/example/profiler"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    if Dir.exist?(".git")
      `git ls-files -z`.split("\x0").reject do |f|
        (File.expand_path(f) == __FILE__) ||
          f.start_with?(*%w[bin/ test/ spec/ features/ test_app/ .git .github appveyor Gemfile])
      end
    else
      Dir.glob("**/*", File::FNM_DOTMATCH).reject do |f|
        File.directory?(f) || (File.expand_path(f) == __FILE__) ||
          f.start_with?(*%w[bin/ test/ spec/ features/ test_app/ .git .github appveyor Gemfile])
      end
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "rack", ">= 2.0"
  spec.add_dependency "concurrent-ruby", "~> 1.2"

  # Development dependencies
  spec.add_development_dependency "rspec-rails", "~> 6.0"
  spec.add_development_dependency "webmock", "~> 3.18"
  spec.add_development_dependency "rake", "~> 13.0"
end
