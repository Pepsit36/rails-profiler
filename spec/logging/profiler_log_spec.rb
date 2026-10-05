# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"
require "profiler/cluster/master_client"

# The profiler's own errors go where the application's logs go: Rails.logger when there is one,
# $stderr otherwise, or config.logger when the application sets it. Always prefixed [Profiler],
# never raising, and never carrying the profiler's credentials.
RSpec.describe "Profiler's own log messages" do
  let(:io) { StringIO.new }
  let(:logger) { Logger.new(io) }

  def with_rails_logger(rails_logger)
    if defined?(::Rails) && ::Rails.respond_to?(:logger)
      allow(::Rails).to receive(:logger).and_return(rails_logger)
    else
      stub_const("Rails", Module.new.tap { |rails| rails.define_singleton_method(:logger) { rails_logger } })
    end
  end

  let(:failing_storage) do
    Class.new(Profiler::Storage::BaseStore) do
      def do_save(_token, _profile)
        raise Errno::ENOSPC
      end
    end.new
  end

  let(:html_app) { ->(_env) { [200, { "content-type" => "text/html" }, ["<html><body>hi</body></html>"]] } }

  def request_env
    Rack::MockRequest.env_for("http://localhost/page", "REMOTE_ADDR" => "127.0.0.1")
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = [Profiler::Collectors::RequestCollector]
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
  end

  describe "Profiler.log_error" do
    it "writes to Rails.logger, prefixed, with the error's class and message" do
      with_rails_logger(logger)

      expect { Profiler.log_error("Somewhere: could not do it", RuntimeError.new("boom")) }.not_to output.to_stderr
      expect(io.string).to match(/ERROR -- : \[Profiler\] Somewhere: could not do it: RuntimeError: boom$/)
    end

    it "writes to $stderr when the application has no logger" do
      with_rails_logger(nil)

      expect { Profiler.log_error("Somewhere: could not do it", RuntimeError.new("boom")) }
        .to output("[Profiler] Somewhere: could not do it: RuntimeError: boom\n").to_stderr
    end

    it "writes to config.logger when the application sets one, before Rails.logger" do
      with_rails_logger(Logger.new(nil))
      Profiler.configuration.logger = logger

      Profiler.log_error("Somewhere: could not do it")
      expect(io.string).to include("[Profiler] Somewhere: could not do it")
    end

    it "never raises, even when the logger does, and then falls back on $stderr" do
      broken = Logger.new(nil)
      allow(broken).to receive(:error).and_raise(IOError, "closed stream")
      with_rails_logger(broken)

      expect { Profiler.log_error("Somewhere: could not do it", RuntimeError.new("boom")) }
        .to output(/\[Profiler\] Somewhere: could not do it: RuntimeError: boom/).to_stderr
    end

    it "never raises when $stderr is closed as well" do
      with_rails_logger(nil)
      closed = StringIO.new.tap(&:close)
      original = $stderr
      $stderr = closed
      expect { Profiler.log_error("Somewhere", RuntimeError.new("boom")) }.not_to raise_error
    ensure
      $stderr = original
    end

    it "masks the cluster secret in the message and in the error" do
      secret = "s3cr3t-cluster-value-0123456789abcdef"
      Profiler.configuration.cluster_secret = secret
      with_rails_logger(logger)

      Profiler.log_error("Cluster: posting #{secret}", RuntimeError.new("refused #{secret}"))
      expect(io.string).to include("[Profiler] Cluster: posting")
      expect(io.string).not_to include(secret)
    end

    it "masks the cluster secret before cutting a long error message, also when the cut falls inside it" do
      secret = "s3cr3t-cluster-value-0123456789abcdef"
      Profiler.configuration.cluster_secret = secret
      with_rails_logger(logger)

      [10, 20, 29, 39].each do |inside|
        message = "#{"x" * (Profiler::LOG_ERROR_MESSAGE_LIMIT - inside)}#{secret} and more"
        Profiler.log_error("Somewhere", RuntimeError.new(message))
      end
      expect(io.string).not_to include(secret[0, 12])
    end

    it "keeps the error's class when its message raises" do
      with_rails_logger(logger)
      error = RuntimeError.new("boom")
      error.define_singleton_method(:message) { raise ArgumentError, "no message" }

      expect { Profiler.log_error("Somewhere", error) }.not_to raise_error
      expect(io.string).to include("[Profiler] Somewhere: RuntimeError")
    end

    it "adds the backtrace when asked" do
      with_rails_logger(logger)
      error = RuntimeError.new("boom")
      error.set_backtrace(["app.rb:1:in `x'", "app.rb:2:in `y'"])

      Profiler.log_error("Somewhere", error, backtrace: true)
      expect(io.string).to include("RuntimeError: boom\napp.rb:1:in `x'\napp.rb:2:in `y'")
    end
  end

  describe "the request middleware" do
    it "reports a storage error through Profiler.save_profile, to the application's log" do
      with_rails_logger(logger)
      Profiler.instance_variable_set(:@storage, failing_storage)

      status = nil
      expect { status, = Profiler::Middleware::ProfilerMiddleware.new(html_app).call(request_env) }
        .not_to output.to_stderr
      expect(status).to eq(200)
      expect(io.string).to match(/\[Profiler\] ProfilerMiddleware: could not save profile \h+: Errno::ENOSPC/)
    end

    it "gives no token and no toolbar to a page whose profile could not be saved" do
      with_rails_logger(logger)
      Profiler.instance_variable_set(:@storage, failing_storage)

      status, headers, body = Profiler::Middleware::ProfilerMiddleware.new(html_app).call(request_env)
      page = +""
      body.each { |part| page << part }

      expect(status).to eq(200)
      expect(headers.keys.map(&:downcase)).not_to include("x-profiler-token")
      expect(page).to eq("<html><body>hi</body></html>")
    end

    it "reports a collector that fails, to the application's log" do
      with_rails_logger(logger)
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      failing = Class.new(Profiler::Collectors::BaseCollector) do
        def collect
          raise ArgumentError, "collector broke"
        end
      end
      Profiler.configuration.collectors = [failing]

      expect { Profiler::Middleware::ProfilerMiddleware.new(html_app).call(request_env) }.not_to output.to_stderr
      expect(io.string).to match(/ERROR -- : \[Profiler\] ProfilerMiddleware: collector .* failed: ArgumentError: collector broke/)
    end
  end

  describe "a streamed response while the store is unavailable" do
    before do
      Profiler.instance_variable_set(:@storage, Profiler::Storage::Unavailable.new(RuntimeError.new("store gone")))
    end

    it "sends no token for a body iterated by the server" do
      streamed = Object.new.tap { |b| b.define_singleton_method(:each) { |&blk| blk.call("chunk") } }
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], streamed] }

      _status, headers, body = Profiler::Middleware::ProfilerMiddleware.new(app).call(request_env)
      body.each { |_| }
      body.close

      expect(headers["x-profiler-token"]).to be_nil
    end

    it "sends no token for a Rack 3 body that writes to the socket itself" do
      callable = ->(stream) { stream.close }
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], callable] }

      _status, headers, = Profiler::Middleware::ProfilerMiddleware.new(app).call(request_env)

      expect(headers["x-profiler-token"]).to be_nil
    end

    it "still sends one when the store is there" do
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      streamed = Object.new.tap { |b| b.define_singleton_method(:each) { |&blk| blk.call("chunk") } }
      app = ->(_env) { [200, Rack::Headers["content-type" => "text/plain"], streamed] }

      _status, headers, body = Profiler::Middleware::ProfilerMiddleware.new(app).call(request_env)
      body.each { |_| }
      body.close

      expect(headers["x-profiler-token"]).to match(/\A\h{32}\z/)
    end
  end

  describe "the Logs tab of the request being profiled" do
    it "does not record the profiler's own messages, nor count them as the application's errors" do
      require "active_support/logger"
      require "active_support/broadcast_logger"
      require "profiler/collectors/log_collector"
      rails_logger = ActiveSupport::BroadcastLogger.new(Logger.new(io))
      with_rails_logger(rails_logger)
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      Profiler.configuration.collectors = [Profiler::Collectors::LogCollector]
      app = lambda do |_env|
        Rails.logger.info("the application's line")
        Profiler.log_error("Somewhere: could not save profile", Errno::ENOSPC.new)
        [200, Rack::Headers["content-type" => "text/plain"], ["ok"]]
      end

      _status, headers, = Profiler::Middleware::ProfilerMiddleware.new(app).call(request_env)
      logs = Profiler.storage.load(headers["x-profiler-token"]).collector_data("logs")

      expect(io.string).to include("[Profiler] Somewhere: could not save profile")
      expect(logs["logs"].map { |line| line["message"] }).to eq(["the application's line"])
      expect(logs["errors"]).to eq(0)
    end
  end

  describe "the cluster client of a slave" do
    it "logs to $stderr instead of raising when Rails has no logger yet" do
      with_rails_logger(nil)

      expect { Profiler::Cluster::MasterClient.new.send(:log_warn, "master unreachable") }
        .to output(/\[Profiler\] Cluster: master unreachable/).to_stderr
    end
  end

  describe "a logger that raises, on every path" do
    let(:raising_logger) do
      Logger.new(nil).tap do |l|
        %i[error warn info].each { |level| l.define_singleton_method(level) { |*| raise IOError, "log device gone" } }
      end
    end

    before { Profiler.configuration.logger = raising_logger }

    it "is read on each message, not when the gem is loaded" do
      Profiler.configuration.logger = logger
      Profiler.log_error("first")
      other = StringIO.new
      Profiler.configuration.logger = Logger.new(other)
      Profiler.log_error("second")

      expect(io.string).to include("first")
      expect(other.string).to include("second")
      expect(io.string).not_to include("second")
    end

    it "never fails a request" do
      Profiler.instance_variable_set(:@storage, failing_storage)
      status = nil
      expect { status, = Profiler::Middleware::ProfilerMiddleware.new(html_app).call(request_env) }
        .to output(/\[Profiler\] ProfilerMiddleware: could not save profile/).to_stderr
      expect(status).to eq(200)
    end

    it "never fails a job" do
      require "profiler/job_profiler"
      Profiler.configuration.track_jobs = true
      Profiler.instance_variable_set(:@storage, failing_storage)
      result = nil
      expect do
        result = Profiler::JobProfiler.profile(job_class: "W", job_id: "1", queue: "q", arguments: [], executions: 0) { :done }
      end.to output(/JobProfiler: could not save profile/).to_stderr
      expect(result).to eq(:done)
    end

    it "never fails a slave's cluster client, at boot or in its heartbeat loop" do
      Profiler.configure do |c|
        c.master_url = "http://127.0.0.1:1"
        c.self_url = "http://127.0.0.1:2"
        c.cluster_secret = "s" * 40
        c.cluster_allow_insecure_http = true
        c.cluster_heartbeat_interval = 0.01
      end
      client = Profiler::Cluster::MasterClient.new
      thread = nil
      allow(client).to receive(:start_heartbeat_thread).and_wrap_original { |original| thread = original.call }

      expect { client.start }.to output(/\[Profiler\] Cluster: could not register with master/).to_stderr
      sleep 0.1
      expect(thread).to be_alive
    ensure
      thread&.kill
    end
  end

  describe "the application's boot, with a logger that raises" do
    it "boots, and the messages reach $stderr" do
      require "open3"
      require "tmpdir"
      script = <<~RUBY
        require "bundler/setup"
        require "logger"
        require "rails"
        require "action_controller/railtie"
        require "profiler"

        class RaisingLogger < Logger
          def add(*) = raise(IOError, "log device gone")
        end

        class ProbeApp < Rails::Application
          config.root = ENV.fetch("PROBE_ROOT")
          config.eager_load = false
          config.secret_key_base = "x" * 64
          config.logger = RaisingLogger.new(nil)
          config.hosts.clear
          config.profiler.enabled = true
          config.profiler.storage = :memory
          config.profiler.no_such_option = 1
        # A cluster node without a usable secret: the boot warns about it.
        config.profiler.cluster_master = true
        end
        Profiler.configuration.memory_warning_threshold = 40
        ProbeApp.initialize!
        puts "booted"
      RUBY
      output, status = Dir.mktmpdir("profiler-raising-logger") do |root|
        Open3.capture2e({ "PROBE_ROOT" => root, "RAILS_ENV" => "development" }, RbConfig.ruby, "-e", script,
                        chdir: File.expand_path("../..", __dir__))
      end

      expect(output).to include("booted"), output
      expect(output).to include("[Profiler] config.profiler.no_such_option is not a profiler option, ignored")
      expect(output).to include("[Profiler] memory_warning_threshold is deprecated")
      expect(output).to include("[Profiler] Cluster: No config.cluster_secret is configured")
      expect(status).to be_success
    end
  end
end
