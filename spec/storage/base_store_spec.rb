# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Storage::BaseStore do
  let(:bus) { instance_double("Profiler::SSE::EventBus", broadcast: nil) }
  let(:store_class) do
    Class.new(described_class) do
      attr_reader :saved

      def self.name
        "Profiler::Storage::SpecStore"
      end

      def do_save(token, profile)
        (@saved ||= {})[token] = profile
        :persisted
      end

      def load(token)
        @saved&.fetch(token, nil)
      end
    end
  end
  let(:store) { store_class.new }

  before do
    allow(Profiler::SSE).to receive(:current).and_return(bus)
    Profiler.instance_variable_get(:@logged_once).clear
  end

  describe "the methods a backend implements" do
    {
      do_save: [SecureRandom.hex(16), nil],
      load: [SecureRandom.hex(16)],
      list: [],
      cleanup: [],
      find_by_parent: [SecureRandom.hex(16)],
      delete: [SecureRandom.hex(16)],
      clear: []
    }.each do |method, args|
      it "raises NotImplementedError naming the backend for ##{method}" do
        expect { described_class.new.public_send(method, *args) }
          .to raise_error(NotImplementedError, "Profiler::Storage::BaseStore must implement ##{method}")
      end
    end
  end

  describe "#save" do
    it "persists through #do_save, announces the token, and returns what #do_save returned" do
      profile = build_profile

      expect(store.save(profile.token, profile)).to eq(:persisted)
      expect(store.saved).to eq(profile.token => profile)
      expect(bus).to have_received(:broadcast).with(profile.token).once
    end

    it "refuses a token the gem did not issue, before writing anything" do
      profile = build_profile

      expect { store.save("../../etc/passwd", profile) }
        .to raise_error(ArgumentError, 'invalid profile token: "../../etc/passwd"')
      expect(store.saved).to be_nil
      expect(bus).not_to have_received(:broadcast)
    end

    it "also announces the request that enqueued a job, for its toolbar to list the job" do
      parent_token = SecureRandom.hex(16)
      job = build_job_profile(parent_token: parent_token)

      store.save(job.token, job)

      expect(bus).to have_received(:broadcast).with(job.token).ordered
      expect(bus).to have_received(:broadcast).with(parent_token).ordered
    end

    it "does not announce the page of an AJAX request, nor a job parent token that is not a token" do
      ajax = build_profile(parent_token: SecureRandom.hex(16), is_ajax: true)
      job = build_job_profile(parent_token: "not-a-token")

      store.save(ajax.token, ajax)
      store.save(job.token, job)

      expect(bus).to have_received(:broadcast).twice
      expect(bus).to have_received(:broadcast).with(ajax.token)
      expect(bus).to have_received(:broadcast).with(job.token)
    end

    it "keeps the profile when the announcement fails, and logs that failure once" do
      allow(bus).to receive(:broadcast).and_raise(IOError, "bus gone")
      first = build_profile
      second = build_profile

      log = capture_profiler_log do
        expect(store.save(first.token, first)).to eq(:persisted)
        expect(store.save(second.token, second)).to eq(:persisted)
      end

      expect(store.saved.keys).to contain_exactly(first.token, second.token)
      expect(log.scan("SpecStore: could not announce a saved profile").size).to eq(1)
      expect(log).to include("IOError")
    end
  end

  describe "#exists?" do
    it "is true for a saved profile and false for an unknown token" do
      profile = build_profile
      store.save(profile.token, profile)

      expect(store.exists?(profile.token)).to be true
      expect(store.exists?(SecureRandom.hex(16))).to be false
    end

    it "answers false when the backend fails, and logs it once" do
      allow(store).to receive(:load).and_raise(Errno::EACCES)

      log = capture_profiler_log do
        2.times { expect(store.exists?(SecureRandom.hex(16))).to be false }
      end

      expect(log.scan("SpecStore: could not look up a profile").size).to eq(1)
      expect(log).to include("Errno::EACCES")
    end
  end
end
