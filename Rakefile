# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# Publishing is the `release` CI job's alone (script/release.sh): it computes the
# version, tags the merged commit and pushes the gem to both registries. The tasks
# `bundler/gem_tasks` defines for it would tag and push version 0.0.0 to
# rubygems.org from any machine holding credentials, so they are replaced by a
# refusal. `build` and `install` stay: they never leave the machine.
release_refusal = "Releases are published by the `release` CI job (script/release.sh) after a merge " \
                  "into master, never from a workstation. See CONTRIBUTING.md, section 5."

%w[release release:rubygem_push release:source_control_push].each do |name|
  Rake::Task[name].clear
  desc "Refuses: the gem is published by the CI, see CONTRIBUTING.md" if name == "release"
  task(name) { abort release_refusal }
end
