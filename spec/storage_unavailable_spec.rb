# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# R-c: a store that cannot be created (its index or lock replaced by a symbolic link, say) is said
# once per process and cause, not with a backtrace on every request; saves are dropped, reads say
# why.
RSpec.describe "Profiler.storage when the store cannot be created" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  before do
    path = File.join(@dir, "profiles")
    FileUtils.mkdir_p(path)
    File.symlink(File.join(@dir, "elsewhere"), File.join(path, Profiler::Storage::FileStore::LOCK_FILE))
    Profiler.configure do |config|
      config.storage = :file
      config.storage_options = { path: path }
    end
    Profiler.instance_variable_set(:@storage, nil)
    Profiler::Storage::Unavailable.reset! if defined?(Profiler::Storage::Unavailable)
  end

  after do
    Profiler.configure { |config| config.storage_options = {} }
    Profiler.instance_variable_set(:@storage, nil)
  end

  it "warns once, drops the saves and lets the reads raise the cause" do
    profiles = Array.new(3) { build_profile }

    output = capture_profiler_log { profiles.each { |p| Profiler.storage.save(p.token, p) } }

    expect(output.lines.size).to eq(1)
    expect(output).to include("symbolic link")
    expect(output).not_to include(".rb:")
    expect { Profiler.storage.list(limit: 5) }.to raise_error(Profiler::Error, /symbolic link/)
  end

  it "uses the store once the cause is gone" do
    capture_stderr { Profiler.storage }
    File.delete(File.join(@dir, "profiles", Profiler::Storage::FileStore::LOCK_FILE))
    profile = build_profile

    Profiler.storage.save(profile.token, profile)

    expect(Profiler.storage.load(profile.token)&.token).to eq(profile.token)
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
