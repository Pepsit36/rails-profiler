# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe "Profiler.version" do
  around do |example|
    Profiler.remove_instance_variable(:@version) if Profiler.instance_variable_defined?(:@version)
    example.run
  ensure
    Profiler.remove_instance_variable(:@version) if Profiler.instance_variable_defined?(:@version)
  end

  def git(dir, *args)
    out, status = Open3.capture2e("git", "-C", dir, *args)
    raise out unless status.success?
  end

  def checkout_with_tag(dir, tag)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    git(dir, "init", "-q")
    git(dir, "config", "user.email", "dev@example.com")
    git(dir, "config", "user.name", "Dev")
    File.write(File.join(dir, "lib", "a.rb"), "1")
    git(dir, "add", ".")
    git(dir, "commit", "-q", "-m", "first")
    git(dir, "tag", tag)
  end

  it "reports a tag of the checkout the gem is mounted from" do
    Dir.mktmpdir do |dir|
      checkout_with_tag(dir, "v2.3.4")
      stub_const("Profiler::GEM_ROOT", dir)

      expect(Profiler.version).to eq("2.3.4")
    end
  end

  it "adds the commits since the tag" do
    Dir.mktmpdir do |dir|
      checkout_with_tag(dir, "v2.3.4")
      File.write(File.join(dir, "lib", "a.rb"), "2")
      git(dir, "commit", "-q", "-am", "second")
      stub_const("Profiler::GEM_ROOT", dir)

      expect(Profiler.version).to match(/\A2\.3\.4-1-g\h+\z/)
    end
  end

  it "falls back to VERSION outside a git checkout, and never runs git there" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      stub_const("Profiler::GEM_ROOT", dir)
      expect(IO).not_to receive(:popen)

      expect(Profiler.version).to eq(Profiler::VERSION)
    end
  end

  it "falls back to VERSION when the checkout has no tag" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      git(dir, "init", "-q")
      stub_const("Profiler::GEM_ROOT", dir)

      expect(Profiler.version).to eq(Profiler::VERSION)
    end
  end

  it "falls back to VERSION when git cannot be run" do
    Dir.mktmpdir do |dir|
      checkout_with_tag(dir, "v2.3.4")
      stub_const("Profiler::GEM_ROOT", dir)
      allow(IO).to receive(:popen).and_raise(Errno::ENOENT)

      expect(Profiler.version).to eq(Profiler::VERSION)
    end
  end

  it "keeps the VERSION a published gem was built with, without asking git" do
    stub_const("Profiler::VERSION", "3.1.4")
    expect(IO).not_to receive(:popen)

    expect(Profiler.version).to eq("3.1.4")
  end
end
