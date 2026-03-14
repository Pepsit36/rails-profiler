# frozen_string_literal: true

namespace :profiler do
  desc "Clean up old profiles"
  task cleanup: :environment do
    older_than = ENV["OLDER_THAN"]&.to_i || 24 * 60 * 60
    puts "Cleaning up profiles older than #{older_than} seconds..."
    Profiler.storage.cleanup(older_than: older_than)
    puts "Cleanup complete!"
  end

  desc "List recent profiles"
  task list: :environment do
    limit = ENV["LIMIT"]&.to_i || 20
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
    puts "Starting Profiler MCP server (#{transport} transport)..."

    server = Profiler::MCP::Server.new
    server.start(transport: transport)
  end
end
