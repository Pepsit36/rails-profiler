# frozen_string_literal: true

require "spec_helper"
require "profiler/middleware/cors_policy"

RSpec.describe Profiler::Middleware::CorsPolicy do
  describe ".warn_about_configuration" do
    let(:logger) { instance_double(Logger, warn: nil) }

    def configure(**options)
      Profiler.configure do |config|
        options.each { |key, value| config.public_send("#{key}=", value) }
      end
    end

    it "warns at boot when wildcard origin is set" do
      configure(extension_cors_enabled: true, cors_allowed_origins: ["*"])
      described_class.warn_about_configuration(logger)

      expect(logger).to have_received(:warn).with(/wildcard origin/)
    end

    it "warns when wildcard origin is mixed with other origins" do
      configure(extension_cors_enabled: true, cors_allowed_origins: ["https://example.com", "*"])
      described_class.warn_about_configuration(logger)

      expect(logger).to have_received(:warn).with(/wildcard origin/)
    end

    it "does not warn when cors is disabled" do
      configure(extension_cors_enabled: false, cors_allowed_origins: ["*"])
      described_class.warn_about_configuration(logger)

      expect(logger).not_to have_received(:warn)
    end

    it "does not warn when only specific origins are configured" do
      configure(extension_cors_enabled: true, cors_allowed_origins: ["https://example.com", "https://another.com"])
      described_class.warn_about_configuration(logger)

      expect(logger).not_to have_received(:warn)
    end

    it "does not warn when no origins are configured" do
      configure(extension_cors_enabled: true, cors_allowed_origins: [])
      described_class.warn_about_configuration(logger)

      expect(logger).not_to have_received(:warn)
    end
  end
end
