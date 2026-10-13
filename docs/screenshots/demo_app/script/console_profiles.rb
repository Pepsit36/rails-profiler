# frozen_string_literal: true

# Console profiles for docs/screenshots: run by run.sh with `bin/rails runner`, it evaluates a
# few expressions the way the profiler's IRB hook does (lib/profiler/instrumentation/
# irb_instrumentation.rb wraps each one in Profiler::ConsoleProfiler.profile).
require "profiler/console_profiler"

[
  'User.where("name LIKE ?", "User%").count',
  "Post.includes(:author).order(:id).limit(3).map { |post| [post.title, post.author.name] }",
  'Rails.cache.fetch("orders/totals") { { count: 128, revenue: 18_420 } }',
  "User.find(999_999)"
].each do |expression|
  Profiler::ConsoleProfiler.profile(expression: expression) { eval(expression) } # rubocop:disable Security/Eval
rescue ActiveRecord::RecordNotFound
  # Recorded as a failed expression, as in a real console session.
end
