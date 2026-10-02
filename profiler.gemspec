# frozen_string_literal: true

require_relative "lib/profiler/version"

Gem::Specification.new do |spec|
  spec.name = "rails-profiler"
  spec.version = Profiler::VERSION
  spec.authors = ["Sébastien Duplessy"]
  spec.email = ["sebastien@duplessy.eu"]

  spec.summary = "Rails profiler with web toolbar and profiling UI"
  spec.description = "A comprehensive Rails profiler with web debug toolbar, profiling UI, SQL analysis, performance timeline, and MCP server integration"
  spec.homepage = "https://git.duplessy.eu/sebastien/rails-profiler-gem"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/-/blob/master/CHANGELOG.md"

  spec.files = Dir.glob("{lib,config,exe}/**/*", base: __dir__).select { |f| File.file?(File.join(__dir__, f)) } +
               Dir.glob("app/{assets/builds,controllers,helpers,views,mailers}/**/*", base: __dir__).select { |f| File.file?(File.join(__dir__, f)) } +
               ["CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies
  spec.add_dependency "rails", ">= 7.0"
  spec.add_dependency "rack", ">= 2.0"
  spec.add_dependency "concurrent-ruby", "~> 1.2"
  spec.add_dependency "mcp"

  # Optional: SQLite storage backend (add to your app's Gemfile if using storage: :sqlite)
  # spec.add_dependency "sqlite3", ">= 1.4"

  # Development dependencies
  spec.add_development_dependency "webmock", "~> 3.18"
  spec.add_development_dependency "rake", "~> 13.0"
end
