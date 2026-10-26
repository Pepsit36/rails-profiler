# frozen_string_literal: true

require "spec_helper"
require "support/mcp_tool_schema"
require "profiler/mcp/tools/query_mailers"

RSpec.describe Profiler::MCP::Tools::QueryMailers do
  let(:store) { Profiler::Storage::MemoryStore.new }
  let(:base_time) { Time.at(Time.now.to_i - 3600) }

  before { Profiler.instance_variable_set(:@storage, store) }
  after { Profiler.instance_variable_set(:@storage, nil) }

  def email(attrs = {})
    {
      "mailer_class" => "UserMailer", "action" => "welcome", "subject" => "Welcome",
      "to" => ["a@example.com"], "delivery_mode" => "deliver_now", "duration_ms" => 4.2
    }.merge(attrs)
  end

  def save(index, emails: [], errors: [])
    build_profile(started_at: base_time + index,
                  collectors_data: { "mailer" => { "emails" => emails, "errors" => errors } })
      .tap { |p| store.save(p.token, p) }
  end

  def text(params = {})
    described_class.call(params).first[:text]
  end

  def rows(output)
    output.lines.map(&:chomp).select { |l| l.start_with?("| ") }.drop(1)
  end

  it "takes only optional filters" do
    schema = mcp_tool_schema("query_mailers")

    expect(schema[:properties].transform_values { |p| p[:type] }).to eq(
      mailer_class: "string", action: "string", delivery_mode: "string", has_error: "boolean",
      limit: "number", fields: "array", cursor: "string", slave: "string"
    )
    expect(schema).not_to have_key(:required)
  end

  it "says so when no profile carries a delivery" do
    save(0)
    build_profile.tap { |p| store.save(p.token, p) }

    expect(text).to eq("No mailer deliveries found matching the criteria.")
  end

  it "lists the deliveries and the failed ones with every column by default" do
    profile = save(0, emails: [email("to" => %w[a@x.io b@x.io c@x.io], "subject" => "S" * 50)],
                      errors: [email("action" => "reset", "error" => "SMTP down", "duration_ms" => nil)])

    output = text

    expect(output).to start_with("# Mailer Deliveries\n\nFound 2 emails:\n")
    expect(output).to include("| Time | Mailer | Action | Subject | To | Mode | Duration | Status | Token |")
    expect(rows(output)).to eq([
      "| #{profile.started_at.strftime('%H:%M:%S')} | UserMailer | welcome | #{'S' * 40} | a@x.io, b@x.io, … | deliver_now | 4.2ms | ✅ | #{profile.token} |",
      "| #{profile.started_at.strftime('%H:%M:%S')} | UserMailer | reset | Welcome | a@example.com | deliver_now | - | ❌ Error | #{profile.token} |"
    ])
  end

  it "filters on mailer class, action, delivery mode and error" do
    save(0, emails: [email, email("mailer_class" => "AdminMailer"), email("action" => "digest"),
                     email("delivery_mode" => "deliver_later")],
            errors: [email("error" => "boom")])
    fields = { "fields" => %w[mailer action mode status] }

    expect(rows(text(fields.merge("mailer_class" => "admin")))).to eq(["| AdminMailer | welcome | deliver_now | ✅ |"])
    expect(rows(text(fields.merge("action" => "DIG")))).to eq(["| UserMailer | digest | deliver_now | ✅ |"])
    expect(rows(text(fields.merge("delivery_mode" => "deliver_later")))).to eq(["| UserMailer | welcome | deliver_later | ✅ |"])
    expect(rows(text(fields.merge("has_error" => true)))).to eq(["| UserMailer | welcome | deliver_now | ❌ Error |"])
    expect(rows(text(fields.merge("has_error" => "false"))).size).to eq(4)
  end

  it "uses the singular for a single email and keeps only the valid fields" do
    profile = save(0, emails: [email])

    output = text("fields" => %w[token bogus])

    expect(output).to include("Found 1 email:")
    expect(rows(output)).to eq(["| #{profile.token} |"])
  end

  it "gives a cursor when the page is full, and the cursor returns the older deliveries" do
    3.times { |i| save(i, emails: [email("subject" => "mail #{i}")]) }

    first_page = text("limit" => 2, "fields" => %w[subject])
    cursor = first_page[/Next cursor: (\S+)\*/, 1]

    expect(rows(first_page)).to eq(["| mail 2 |", "| mail 1 |"])
    expect(cursor).to eq("#{(base_time + 1).iso8601(6)}|0")
    expect(rows(text("limit" => 2, "fields" => %w[subject], "cursor" => cursor))).to eq(["| mail 0 |"])
  end

  it "does not drop the deliveries of one request that a page boundary splits" do
    save(0, emails: [email("subject" => "old")])
    save(1, emails: [email("subject" => "a"), email("subject" => "b"), email("subject" => "c")])

    first_page = text("limit" => 2, "fields" => %w[subject])
    cursor = first_page[/Next cursor: (\S+)\*/, 1]
    second_page = text("limit" => 2, "fields" => %w[subject], "cursor" => cursor)

    expect(rows(first_page)).to eq(["| a |", "| b |"])
    expect(rows(second_page)).to eq(["| c |", "| old |"])
  end

  it "ignores a cursor that is not a time" do
    save(0, emails: [email])

    expect(text("cursor" => "yesterday-ish")).to include("Found 1 email:")
  end

  it "reads the deliveries of a slave" do
    require "profiler/cluster/slave_proxy"
    proxy = instance_double(Profiler::Cluster::SlaveProxy)
    allow(Profiler::MCP::SlaveSupport).to receive(:resolve_storage).and_return(proxy)
    remote = build_profile(collectors_data: { "mailer" => { "emails" => [email("subject" => "remote")] } })
    expect(proxy).to receive(:list).with(limit: 200).and_return([remote])

    expect(text("slave" => "payment", "fields" => %w[subject])).to include("| remote |")
  end
end
