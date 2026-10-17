# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"

# `bundler/gem_tasks` defines `rake release`, which tags the checkout and pushes
# the gem to rubygems.org from wherever it runs. Publishing belongs to the
# `release` CI job, so the Rakefile replaces those tasks with a refusal.
#
# The Rakefile is loaded in a child process: `bundler/gem_tasks` defines its
# tasks once per process, and a task is only ever invoked there after its one
# action has been checked to come from the Rakefile, so a regression can never
# run the real release from the suite.
RSpec.describe "Rakefile" do
  root = File.expand_path("..", __dir__)
  rakefile = File.join(root, "Rakefile")
  release_tasks = %w[release release:rubygem_push release:source_control_push]

  probe = <<~RUBY
    require "json"
    require "rake"
    Rake.application.init("rake", [])
    Rake.application.load_rakefile
    name = ARGV.fetch(0)
    task = Rake::Task[name]
    info = {
      "prerequisites" => task.prerequisites,
      "actions" => task.actions.map { |action| action.source_location.first },
      "build" => Rake::Task.task_defined?("build"),
      "install" => Rake::Task.task_defined?("install")
    }
    $stdout.puts JSON.generate(info)
    $stdout.flush
    task.invoke if ARGV[1] == "invoke" && info["actions"] == [#{rakefile.inspect}]
  RUBY

  define_method(:rake_probe) do |name, *args|
    Open3.capture3(RbConfig.ruby, "-e", probe, name, *args, chdir: root)
  end

  release_tasks.each do |name|
    describe name do
      it "no longer builds, tags or pushes anything" do
        out, err, status = rake_probe(name)
        info = JSON.parse(out.lines.first.to_s)

        expect(status).to be_success, err
        expect(info["prerequisites"]).to be_empty
        expect(info["actions"]).to eq([rakefile])
      end

      it "refuses and points at the CI release job" do
        out, err, status = rake_probe(name, "invoke")

        expect(JSON.parse(out.lines.first.to_s)["actions"]).to eq([rakefile])
        expect(status).not_to be_success
        expect(err).to include("`release` CI job")
      end
    end
  end

  it "keeps the local build and install tasks" do
    out, err, status = rake_probe("release")
    info = JSON.parse(out.lines.first.to_s)

    expect(status).to be_success, err
    expect(info.values_at("build", "install")).to eq([true, true])
  end
end
