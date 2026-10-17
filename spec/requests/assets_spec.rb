# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"

# The gem's built files are named by a digest of their content, so that a browser keeps one
# for a year and still gets the next one after an upgrade of the gem.
RSpec.describe "Versioned assets", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:builds) { Pathname.new(Dir.mktmpdir("profiler-builds")) }

  def app
    Rails.application
  end

  before do
    Profiler.configure { |c| c.enabled = true }
    allow(Profiler::Engine).to receive(:root).and_return(builds.join("root"))
    FileUtils.mkdir_p(builds.join("root", *Profiler::Assets::BUILDS))
    write("profiler.js", "console.log('main')")
    write("profiler.css", "body{}")
    write("profiler-toolbar.js", "console.log('toolbar')")
    Profiler::Assets.instance_variable_set(:@entries, {})
  end

  after { FileUtils.remove_entry(builds) }

  def write(name, content)
    File.write(builds.join("root", *Profiler::Assets::BUILDS, name), content)
  end

  Profiler::Assets::NAMES.each do |name|
    context name do
      it "is served for a year under its versioned URL" do
        get Profiler::Assets.url(name), {}, local

        expect(last_response.status).to eq(200)
        expect(last_response.headers["Cache-Control"].split(", ")).to contain_exactly("public", "max-age=31536000", "immutable")
      end

      it "is kept an hour under its bare URL or a stale version" do
        get "/_profiler/assets/#{name}", {}, local
        expect(last_response.headers["Cache-Control"]).to eq("max-age=3600, public")

        get "/_profiler/assets/#{name}?v=deadbeef", {}, local
        expect(last_response.headers["Cache-Control"]).to eq("max-age=3600, public")
      end
    end
  end

  it "changes the URL when the content changes" do
    before = Profiler::Assets.url("profiler.js")
    write("profiler.js", "console.log('next')")
    File.utime(Time.now + 5, Time.now + 5, builds.join("root", *Profiler::Assets::BUILDS, "profiler.js"))

    expect(Profiler::Assets.url("profiler.js")).not_to eq(before)
  end

  it "reads each file once while it does not change" do
    expect(File).to receive(:read).once.and_call_original
    3.times { Profiler::Assets.read("profiler.css") }
  end

  it "falls back to the gem version when the assets are not built" do
    FileUtils.rm(builds.join("root", *Profiler::Assets::BUILDS, "profiler.css"))

    expect(Profiler::Assets.url("profiler.css")).to match(%r{\A/_profiler/assets/profiler\.css\?v=\h{12}\z})
  end

  it "points the layouts and the toolbar at the versioned URLs" do
    expect(Profiler::Middleware::ToolbarInjector.new(["<body></body>"], "t").inject.join)
      .to include(%(src="#{Profiler::Assets.url('profiler-toolbar.js')}"))
  end
end
