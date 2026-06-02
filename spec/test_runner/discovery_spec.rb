# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "pathname"
require "profiler/test_runner/discovery"

RSpec.describe Profiler::TestRunner::Discovery do
  let(:tmpdir) do
    dir = Dir.mktmpdir("profiler_discovery_spec")
    FileUtils.mkdir_p(File.join(dir, "spec/models"))
    FileUtils.mkdir_p(File.join(dir, "spec/controllers"))
    FileUtils.mkdir_p(File.join(dir, "test/models"))

    File.write(File.join(dir, "spec/models/post_spec.rb"), "")
    File.write(File.join(dir, "spec/models/user_spec.rb"), "")
    File.write(File.join(dir, "spec/controllers/home_controller_spec.rb"), "")
    File.write(File.join(dir, "test/models/user_test.rb"), "")
    dir
  end

  before do
    rails_root = Pathname.new(tmpdir)
    rails_stub = Module.new
    rails_stub.define_singleton_method(:root) { rails_root }
    rails_stub.define_singleton_method(:to_s) { "Rails" }
    stub_const("Rails", rails_stub)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe ".files" do
    context "without framework filter" do
      it "returns both rspec and minitest files" do
        result = described_class.files
        all_paths = result.flat_map { |d| d[:files].map { |f| f[:path] } }
        expect(all_paths).to include(match(/_spec\.rb$/))
        expect(all_paths).to include(match(/_test\.rb$/))
      end
    end

    context "with framework: :rspec" do
      it "returns only spec files" do
        result = described_class.files(framework: :rspec)
        all_paths = result.flat_map { |d| d[:files].map { |f| f[:path] } }
        expect(all_paths.all? { |p| p.end_with?("_spec.rb") }).to be true
        expect(all_paths).not_to include(match(/_test\.rb$/))
      end
    end

    context "with framework: :minitest" do
      it "returns only test files" do
        result = described_class.files(framework: :minitest)
        all_paths = result.flat_map { |d| d[:files].map { |f| f[:path] } }
        expect(all_paths.all? { |p| p.end_with?("_test.rb") }).to be true
        expect(all_paths).not_to include(match(/_spec\.rb$/))
      end
    end

    it "groups files by directory" do
      result = described_class.files(framework: :rspec)
      dirs = result.map { |d| d[:directory] }
      expect(dirs).to include("spec/models", "spec/controllers")
    end

    it "sorts files by name within a directory" do
      result = described_class.files(framework: :rspec)
      models_dir = result.find { |d| d[:directory] == "spec/models" }
      names = models_dir[:files].map { |f| f[:name] }
      expect(names).to eq(names.sort)
    end

    it "sorts directories alphabetically" do
      result = described_class.files(framework: :rspec)
      dirs = result.map { |d| d[:directory] }
      expect(dirs).to eq(dirs.sort)
    end

    it "returns relative paths" do
      result = described_class.files(framework: :rspec)
      all_paths = result.flat_map { |d| d[:files].map { |f| f[:path] } }
      expect(all_paths.none? { |p| p.start_with?("/") }).to be true
    end
  end

  describe ".frameworks" do
    it "returns an array" do
      expect(described_class.frameworks).to be_an(Array)
    end

    it "returns :rspec since rspec is running" do
      # RSpec IS loaded in the spec environment, so rspec_available? is always true
      expect(described_class.frameworks).to include(:rspec)
    end

    it "returns :minitest when minitest gem is in loaded_specs" do
      allow(Gem).to receive(:loaded_specs).and_return(
        Gem.loaded_specs.merge("minitest" => double)
      )
      expect(described_class.frameworks).to include(:minitest)
    end
  end
end
