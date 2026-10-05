# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "sqlite3"
require "profiler/storage/sqlite_store"
require "profiler/collectors/request_collector"
require_relative "../support/fake_redis"

# PERF-05: with compress_bodies (the default), a text body larger than compress_body_threshold is
# kept gzip+base64, and that is the form every store writes. Profile#to_h decompressed it, so the
# stores received the text and the compression only cost time.
RSpec.describe "Bodies compressed by compress_bodies, as stored" do
  around(:each) do |example|
    Dir.mktmpdir do |tmpdir|
      @tmpdir = tmpdir
      example.run
    end
  end

  # About 30 KB of HTML, above the 10 KB threshold, with a marker to search the stored bytes for.
  let(:body) { "<html><body>#{(1..600).map { |i| "<p>stored-body-marker row #{i}</p>" }.join}</body></html>" }

  let(:profile) do
    profile = Profiler::Models::Profile.new
    profile.path = "/page"
    profile.method = "GET"
    profile.set_bodies(request_body: "", response_body: body, req_content_type: "", resp_content_type: "text/html")
    profile.finish(200, { "Content-Type" => "text/html" })
    Profiler::Collectors::RequestCollector.new(profile).collect
    profile
  end

  def stored_bytes(store_name)
    case store_name
    when :file
      Profiler::Storage::FileStore.new(path: @tmpdir).save(profile.token, profile)
      File.read(File.join(@tmpdir, "#{profile.token}.json"))
    when :redis
      redis = FakeRedis.new
      Profiler::Storage::RedisStore.new(redis: redis, key_prefix: "p").save(profile.token, profile)
      redis.get("p:#{profile.token}")
    when :memory
      store = Profiler::Storage::MemoryStore.new
      store.save(profile.token, profile)
      JSON.generate(store.instance_variable_get(:@profiles).fetch(profile.token))
    when :sqlite
      Profiler::Storage::SqliteStore.new(database: File.join(@tmpdir, "p.sqlite3"), blob_path: File.join(@tmpdir, "blobs"))
                                    .save(profile.token, profile)
      db = SQLite3::Database.new(File.join(@tmpdir, "p.sqlite3"))
      db.execute("SELECT * FROM profiler_profiles").flatten.join
    end
  end

  %i[file redis memory sqlite].each do |store_name|
    it "keeps the body compressed in the #{store_name} store" do
      stored = stored_bytes(store_name)

      expect(stored).not_to include("stored-body-marker")
      expect(stored.bytesize).to be < body.bytesize / 2
    end
  end

  def store_for(store_name)
    case store_name
    when :file then Profiler::Storage::FileStore.new(path: @tmpdir)
    when :redis then Profiler::Storage::RedisStore.new(redis: FakeRedis.new, key_prefix: "p")
    when :memory then Profiler::Storage::MemoryStore.new
    when :sqlite
      Profiler::Storage::SqliteStore.new(database: File.join(@tmpdir, "p.sqlite3"), blob_path: File.join(@tmpdir, "blobs"))
    end
  end

  %i[file redis memory sqlite].each do |store_name|
    it "gives the body back as text when a profile read from the #{store_name} store is shown" do
      store = store_for(store_name)
      store.save(profile.token, profile)
      shown = store.load(profile.token).to_h(decode_bodies: true)

      expect(shown[:response_body]).to eq(body)
      expect(shown[:response_body_encoding]).to eq("text")
    end
  end

  it "writes the stored form in Profile#to_h" do
    data = profile.to_h

    expect(data[:response_body_encoding]).to eq("gzip+base64")
    expect(data[:response_body]).to eq(profile.response_body)
    expect(Profiler::Models::Profile.from_hash(data).response_body).to eq(profile.response_body)
  end

  it "compresses at the fastest zlib level" do
    expect(Zlib::Inflate.inflate(Base64.strict_decode64(profile.response_body))).to eq(body)
    expect(Base64.strict_decode64(profile.response_body).byteslice(0, 2).unpack1("n")).to eq(0x7801)
  end

  it "stores the text when compress_bodies is false" do
    Profiler.configure { |c| c.compress_bodies = false }

    data = profile.to_h
    expect(data[:response_body]).to eq(body)
    expect(data[:response_body_encoding]).to eq("text")
  end

  it "stores a body under compress_body_threshold as text" do
    Profiler.configure { |c| c.compress_body_threshold = body.bytesize }

    expect(profile.to_h.values_at(:response_body, :response_body_encoding)).to eq([body, "text"])
  end

  # Every earlier version wrote the bodies as text, with or without an encoding.
  it "reads a profile stored as text by an earlier version, with no migration" do
    json = JSON.generate(token: "a" * 32, path: "/old", method: "GET", response_body: body,
                         response_body_encoding: "text", request_body: "q=1")
    File.write(File.join(@tmpdir, "#{"a" * 32}.json"), json)

    shown = Profiler::Storage::FileStore.new(path: @tmpdir).load("a" * 32).to_h(decode_bodies: true)
    expect(shown.values_at(:response_body, :response_body_encoding)).to eq([body, "text"])
    expect(shown.values_at(:request_body, :request_body_encoding)).to eq(["q=1", "text"])
  end

  # An earlier version reading this one's store runs the same from_hash and decompressed in its
  # to_h, what decode_bodies: true does.
  it "stores a profile that from_hash and a decompressing to_h read back as text" do
    stored = JSON.parse(profile.to_json, symbolize_names: true)

    expect(Profiler::Models::Profile.from_hash(stored).to_h(decode_bodies: true)[:response_body]).to eq(body)
  end

  it "shows a damaged compressed body as it is, without raising" do
    %w[not-base64!! AAAA].each do |damaged|
      broken = Profiler::Models::Profile.from_hash(token: "b" * 32, response_body: damaged,
                                                   response_body_encoding: "gzip+base64")

      expect(broken.to_h(decode_bodies: true).values_at(:response_body, :response_body_encoding))
        .to eq([damaged, "gzip+base64"])
    end
  end

  it "lists no copy of the bodies in the summary" do
    summary = Profiler::Storage::Summary.build(profile)

    expect(summary[:collectors_data]["request"].keys)
      .not_to include("request_body", "request_body_encoding", "response_body", "response_body_encoding")
    expect(summary[:collectors_data]["request"]["path"]).to eq("/page")
  end

  context "with a secret in a body above the threshold" do
    let(:secret) { "cluster-secret-that-must-not-leak-1234" }
    let(:json_body) do
      JSON.generate(items: (1..500).map { |i| { id: i, name: "item #{i}" } }, password: "hunter2-planted", note: secret)
    end
    let(:profile) do
      profile = Profiler::Models::Profile.new
      profile.path = "/api"
      profile.method = "POST"
      profile.set_bodies(request_body: json_body, response_body: json_body,
                         req_content_type: "application/json", resp_content_type: "application/json")
      profile.finish(200, {})
      Profiler::Collectors::RequestCollector.new(profile).collect
      profile
    end

    before { Profiler.configure { |c| c.cluster_secret = secret } }

    it "masks it before the compression, so no decompression shows it" do
      expect(profile.response_body_encoding).to eq("gzip+base64")

      store = Profiler::Storage::FileStore.new(path: @tmpdir)
      store.save(profile.token, profile)
      shown = store.load(profile.token).to_h(decode_bodies: true)
      request = shown[:collectors_data]["request"]
      decoded = [shown[:request_body], shown[:response_body],
                 Profiler::Models::Profile.decode_body(request["request_body"], request["request_body_encoding"]).first,
                 Profiler::Models::Profile.decode_body(request["response_body"], request["response_body_encoding"]).first]

      decoded.each do |text|
        expect(text).to include("item 500")
        expect(text).not_to include(secret)
        expect(text).not_to include("hunter2-planted")
      end
    end
  end
end
