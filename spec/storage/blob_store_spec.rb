# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "securerandom"
require "profiler/storage/blob_store"

RSpec.describe Profiler::Storage::BlobStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:store) { described_class.new(@dir) }
  let(:data) { { "requests" => [{ "url" => "https://api.test/" }] } }

  describe "#prune" do
    let(:tokens) { Array.new(3) { SecureRandom.hex(16) } }

    before do
      tokens.each do |tok|
        store.write(tok, "http", data)
        File.utime(Time.now - 60, Time.now - 60, File.join(@dir, tok))
      end
    end

    it "skips a directory removed by another worker without logging, and prunes the others" do
      vanished = tokens.first
      real_lstat = File.method(:lstat)
      allow(File).to receive(:lstat) do |path|
        raise Errno::ENOENT, path if path.to_s == File.join(@dir, vanished)

        real_lstat.call(path)
      end
      allow(Profiler).to receive(:log_error)

      expect { store.prune([], grace: 10) }.not_to raise_error

      expect(Profiler).not_to have_received(:log_error)
      tokens.drop(1).each { |tok| expect(File.exist?(File.join(@dir, tok))).to be(false) }
    end

    it "logs other system errors and keeps pruning" do
      denied = tokens.first
      real_lstat = File.method(:lstat)
      allow(File).to receive(:lstat) do |path|
        raise Errno::EACCES, path if path.to_s == File.join(@dir, denied)

        real_lstat.call(path)
      end
      allow(Profiler).to receive(:log_error)

      store.prune([], grace: 10)

      expect(Profiler).to have_received(:log_error).with(/could not prune #{denied}/, instance_of(Errno::EACCES))
      tokens.drop(1).each { |tok| expect(File.exist?(File.join(@dir, tok))).to be(false) }
    end
  end
end
