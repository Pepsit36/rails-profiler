# frozen_string_literal: true

module Profiler
  module Tasks
    # The whole number an environment variable gives, or default when it is not set. An empty or
    # non-numeric value ("", "abc", "1h") stops the task: read as 0, OLDER_THAN would delete every
    # profile.
    def self.integer_env(name, default, minimum:, unit:)
      value = ENV[name]
      return default if value.nil?
      return Integer(value, 10) if value.match?(/\A\d+\z/) && Integer(value, 10) >= minimum

      warn "#{name} must be a whole number of #{unit} (#{minimum} or more), got #{value.inspect}."
      exit 1
    end
  end
end

namespace :profiler do
  desc "Clean up old profiles (OLDER_THAN: seconds, 86400 by default)"
  task cleanup: :environment do
    older_than = Profiler::Tasks.integer_env("OLDER_THAN", 24 * 60 * 60, minimum: 0, unit: "seconds")
    puts "Cleaning up profiles older than #{older_than} seconds..."
    Profiler.storage.cleanup(older_than: older_than)
    puts "Cleanup complete!"
  end

  desc "List recent profiles (LIMIT: 20 by default)"
  task list: :environment do
    limit = Profiler::Tasks.integer_env("LIMIT", 20, minimum: 1, unit: "profiles")
    profiles = Profiler.storage.list(limit: limit)

    if profiles.empty?
      puts "No profiles found."
    else
      puts "\nRecent Profiles:"
      puts "=" * 100
      printf "%-10s %-8s %-40s %-10s %-10s %s\n", "TIME", "METHOD", "PATH", "DURATION", "STATUS", "TOKEN"
      puts "-" * 100

      profiles.each do |profile|
        time = profile.started_at.strftime("%H:%M:%S")
        printf "%-10s %-8s %-40s %-10s %-10s %s\n",
               time,
               profile.method,
               profile.path.truncate(40),
               "#{profile.duration}ms",
               profile.status,
               profile.token
      end
    end
  end

  desc "Show profile details"
  task show: :environment do
    token = ENV["TOKEN"]
    unless token
      puts "Usage: rake profiler:show TOKEN=<token>"
      exit 1
    end

    profile = Profiler.storage.load(token)
    unless profile
      puts "Profile not found: #{token}"
      exit 1
    end

    puts "\nProfile: #{token}"
    puts "=" * 100
    puts "Path:     #{profile.path}"
    puts "Method:   #{profile.method}"
    puts "Status:   #{profile.status}"
    puts "Duration: #{profile.duration}ms"
    puts "Memory:   #{(profile.memory / 1024.0 / 1024.0).round(2)}MB" if profile.memory
    puts "Started:  #{profile.started_at}"
    puts "\nCollectors Data:"
    puts "-" * 100

    profile.collectors_data.each do |name, data|
      puts "\n#{name.capitalize}:"
      puts JSON.pretty_generate(data)
    end
  end

  desc "Start MCP server"
  task mcp: :environment do
    require_relative "../mcp/server"

    transport = ENV["MCP_TRANSPORT"]&.to_sym || Profiler.configuration.mcp_transport
    $stderr.puts "Starting Profiler MCP server (#{transport} transport)..."

    server = Profiler::MCP::Server.new
    server.start(transport: transport)
  end
end
