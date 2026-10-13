# frozen_string_literal: true

# Screenshot overlay: copied into the superproject's test_app by docs/screenshots/run.sh.
# Every host is fictitious (*.myapp.test) and resolved to 127.0.0.1 by the browser or below.
Rails.application.config.hosts << ".myapp.test"

# A checkout of the gem carries version 0.0.0 (the release job sets the real one): show the
# version run.sh read from CHANGELOG.md instead.
if (version = ENV["PROFILER_DEMO_VERSION"]).present? && Profiler::VERSION == "0.0.0"
  Profiler.send(:remove_const, :VERSION)
  Profiler.const_set(:VERSION, version)
end

# The mail gem names the machine in each Message-ID: use a fictitious domain instead.
ActiveSupport.on_load(:action_mailer) do
  default "Message-ID" => -> { "<#{SecureRandom.hex(12)}@myapp.test>" }
end

Profiler.configure do |config|
  # Only these values are shown in the Env tab; every other variable is listed masked, so no
  # path or machine name of the host running the screenshots ends up in an image.
  config.env_allowlist = %w[RAILS_ENV APP_NAME APP_ENV APP_VERSION CACHE_STORE LOG_LEVEL
                            FEATURE_DARK_MODE FEATURE_BETA_UI FEATURE_NEW_SEARCH FEATURE_ANALYTICS]
  # The fake billing API below lives in the same application: keep its requests out of the list.
  config.skip_paths += [%r{\A/upstream/}, %r{\A/up\z}]

  if (secret = ENV["PROFILER_CLUSTER_SECRET"])
    config.cluster_secret = secret
    if ENV["PROFILER_CLUSTER_MASTER"] == "true"
      config.cluster_master = true
      config.cluster_allowed_slave_urls = [%r{\Ahttp://localhost:30\d\d\z}]
    end
  end
end
