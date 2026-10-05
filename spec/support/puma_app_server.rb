# frozen_string_literal: true

require "net/http"
require "rbconfig"
require "socket"
require "timeout"

# The spec Rails application served by a real Puma in a child process (see
# puma_app_server_boot.rb), so that a spec can hold connections open the way browsers do and
# time what the application still answers.
class PumaAppServer
  BOOT_SCRIPT = File.expand_path("puma_app_server_boot.rb", __dir__)
  BOOT_TIMEOUT = 60

  attr_reader :port, :run_id

  def initialize(threads:)
    @threads = threads
    @sockets = []
  end

  # Returns once the child listens and has answered a first application request, so that
  # nothing measured afterwards includes the boot or the first request's warm-up. Kills the
  # child when it does not get there.
  def start
    @reader, writer = IO.pipe
    @pid = Process.spawn(RbConfig.ruby, BOOT_SCRIPT, @threads.to_s, out: writer, err: File::NULL)
    writer.close
    Timeout.timeout(BOOT_TIMEOUT) do
      while (line = @reader.gets)
        @port = Integer(line.split("=", 2).last) if line.start_with?("PORT=")
        @run_id = line.split("=", 2).last.strip if line.start_with?("RUN=")
        break if @port && @run_id
      end
      raise "the Puma child process exited before listening" unless @port && @run_id

      sleep 0.1 until time_request("/hello", limit: BOOT_TIMEOUT) < BOOT_TIMEOUT
    end
    self
  rescue Exception # rubocop:disable Lint/RescueException
    stop
    raise
  end

  def stop
    @sockets.each { |socket| socket.close unless socket.closed? }
    @reader&.close unless @reader&.closed?
    return unless @pid

    begin
      Process.kill("KILL", @pid)
      Process.wait(@pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    @pid = nil
  end

  # Sends a GET on a raw connection and leaves it open, as an EventSource does.
  def open_connection(path)
    socket = TCPSocket.new("127.0.0.1", @port)
    socket.write("GET #{path} HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n")
    @sockets << socket
    socket
  end

  # The status line and headers answered on +socket+, as far as they came within +limit+.
  def read_head(socket, limit:)
    head = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + limit
    until head.include?("\r\n\r\n")
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0 || !socket.wait_readable(remaining)

      chunk = socket.read_nonblock(4096, exception: false)
      break if chunk.nil?

      head << chunk unless chunk == :wait_readable
    end
    head
  end

  # Seconds the application takes to answer GET +path+, or +limit+ when it has not answered by
  # then.
  def time_request(path, limit:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    http = Net::HTTP.new("127.0.0.1", @port)
    http.open_timeout = limit
    http.read_timeout = limit
    http.start { |connection| connection.get(path, "Host" => "localhost") }
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  rescue Net::ReadTimeout, Net::OpenTimeout, SystemCallError
    limit
  end
end
