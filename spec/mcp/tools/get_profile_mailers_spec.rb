# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "support/mcp_tool_schema"
require "profiler/mcp/file_cache"
require "profiler/mcp/path_extractor"
require "profiler/mcp/body_formatter"
require "profiler/mcp/tools/get_profile_mailers"

RSpec.describe Profiler::MCP::Tools::GetProfileMailers do
  let(:store) { Profiler::Storage::MemoryStore.new }
  let(:tmp_dir) { Dir.mktmpdir }

  before do
    Profiler.configure { |c| c.tmp_path = Pathname.new(tmp_dir) }
    Profiler.instance_variable_set(:@storage, store)
  end

  after do
    Profiler.instance_variable_set(:@storage, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def email(attrs = {})
    {
      "mailer_class" => "UserMailer", "action" => "welcome", "subject" => "Welcome!",
      "to" => ["ann@example.com"], "from" => ["noreply@example.com"],
      "delivery_method" => "smtp", "delivery_mode" => "deliver_now"
    }.merge(attrs)
  end

  def save(mailer)
    build_profile(method: "POST", path: "/signup", collectors_data: { "mailer" => mailer })
      .tap { |p| store.save(p.token, p) }
  end

  def text(params)
    described_class.call(params).first[:text]
  end

  it "requires a token, with optional filters and body options" do
    schema = mcp_tool_schema("get_profile_mailers")

    expect(schema[:properties].transform_values { |p| p[:type] }).to eq(
      token: "string", mailer_class: "string", action: "string", delivery_mode: "string",
      save_bodies: "boolean", max_body_size: "number", slave: "string"
    )
    expect(schema[:required]).to eq(["token"])
  end

  it "asks for the token when it is missing" do
    expect(text({})).to eq("Error: token parameter is required")
  end

  it "says so when the profile does not exist" do
    expect(text("token" => "b" * 32)).to eq("Profile not found: #{'b' * 32}")
  end

  it "says so when the profile sent and queued nothing" do
    plain = build_profile.tap { |p| store.save(p.token, p) }
    idle = save("total" => 0, "queued_count" => 0)

    expect(text("token" => plain.token)).to eq("No mailer activity found in this profile")
    expect(text("token" => idle.token)).to eq("No mailer activity found in this profile")
  end

  it "describes the delivered, failed and queued emails" do
    delivered = email(
      "cc" => ["cc@example.com"], "bcc" => ["bcc@example.com"], "reply_to" => ["help@example.com"],
      "message_id" => "<m1@example.com>", "duration_ms" => 3.5, "delivery_ms" => 12.0,
      "parts" => ["text/html", "text/plain"], "attachments" => [{ "filename" => "invoice.pdf", "size" => 2048 }],
      "assigns" => { "user" => "Ann" }, "body_captured" => true,
      "body_html" => "<p>Hello Ann</p>", "body_text" => "Hello Ann"
    )
    failed = email("action" => "reset_password", "error" => "Net::SMTPFatalError")
    queued = { "mailer_class" => "DigestMailer", "action" => "weekly", "delivery_method" => "smtp",
               "duration_ms" => 1.25, "assigns" => { "week" => 42 } }
    profile = save("total" => 1, "queued_count" => 1, "failed" => 1,
                   "emails" => [delivered], "errors" => [failed], "queued" => [queued],
                   "loop_warnings" => [{ "message" => "UserMailer#welcome sent 3 times" }])

    output = text("token" => profile.token)

    expect(output).to include(<<~MD.chomp)
      # Mailer Activity: #{profile.token}

      **Request:** POST /signup
      **Delivered:** 1 email(s)
      **Queued (deliver_later):** 1 email(s)
      **Errors:** 1
      **Body captured:** yes

      ⚠️ **Loop warnings:**
        - UserMailer#welcome sent 3 times

      ## Delivered Emails

      ### Email 1: UserMailer#welcome
      - **Subject:** Welcome!
      - **To:** ann@example.com
      - **From:** noreply@example.com
      - **CC:** cc@example.com
      - **BCC:** bcc@example.com
      - **Reply-To:** help@example.com
      - **Message-ID:** <m1@example.com>
      - **Delivery method:** smtp
      - **Mode:** deliver_now
      - **Render duration:** 3.5ms
      - **Delivery duration:** 12.0ms
      - **Parts:** text/html, text/plain
      - **Attachments:**
        - invoice.pdf (2048 bytes)
      - **Template assigns:**
        - `user`: Ann
      - **HTML body:**
      ```
      <p>Hello Ann</p>
      ```
      - **Text body:**
      ```
      Hello Ann
      ```
    MD
    expect(output).to include(
      "## Errors\n\n### Email 1: UserMailer#reset_password",
      "- **Error:** Net::SMTPFatalError",
      "- **Body:** not captured (enable `capture_mail_body: true` in initializer)",
      <<~MD.chomp
        ## Queued (deliver_later)

        ### Queued 1: DigestMailer#weekly
        - **Delivery method:** smtp
        - **Render duration:** 1.25ms
        - **Template assigns:**
          - `week`: 42
      MD
    )
  end

  it "says the body was not captured when capture_mail_body is off" do
    profile = save("total" => 1, "emails" => [email])

    expect(text("token" => profile.token)).to include("**Body captured:** no (set capture_mail_body: true)")
  end

  it "reports a profile that only queued emails" do
    profile = save("total" => 0, "queued_count" => 1, "queued" => [{ "mailer_class" => "DigestMailer", "action" => "weekly" }])

    output = text("token" => profile.token)

    expect(output).to include("### Queued 1: DigestMailer#weekly")
    expect(output).not_to include("## Delivered Emails")
  end

  it "filters the emails on mailer class, action and delivery mode" do
    profile = save("total" => 3, "emails" => [
      email, email("mailer_class" => "AdminMailer", "action" => "alert"),
      email("action" => "digest", "delivery_mode" => "deliver_later")
    ])

    expect(text("token" => profile.token, "mailer_class" => "admin").scan(/### Email \d+: (\S+)/).flatten)
      .to eq(["AdminMailer#alert"])
    expect(text("token" => profile.token, "action" => "WEL").scan(/### Email \d+: (\S+)/).flatten)
      .to eq(["UserMailer#welcome"])
    expect(text("token" => profile.token, "delivery_mode" => "deliver_later").scan(/### Email \d+: (\S+)/).flatten)
      .to eq(["UserMailer#digest"])
  end

  it "reads the most recent profile for the latest token, and saves the bodies when asked" do
    save("total" => 1, "emails" => [email("subject" => "older")])
    save("total" => 1, "emails" => [email("subject" => "newer", "body_captured" => true, "body_text" => "Hi")])

    output = text("token" => "latest", "save_bodies" => true)

    expect(output).to include("- **Subject:** newer")
    expect(File.read(output[/saved → `([^`]+)`/, 1])).to eq("Hi")
  end

  it "reads the profile of a slave" do
    require "profiler/cluster/slave_proxy"
    proxy = instance_double(Profiler::Cluster::SlaveProxy)
    remote = save("total" => 1, "emails" => [email("subject" => "remote")])
    allow(Profiler::MCP::SlaveSupport).to receive(:resolve_storage).and_return(proxy)
    expect(proxy).to receive(:list).with(limit: 1).and_return([remote])

    expect(text("token" => "latest", "slave" => "payment")).to include("- **Subject:** remote")
  end
end
