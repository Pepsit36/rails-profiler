# Re-point the compiled /opt/hostedtoolcache prefix to the real install dir,
# so RubyGems/Bundler insert gem paths before the stdlib dirs listed in RUBYLIB.
require "rbconfig"
old = "/opt/hostedtoolcache/Ruby/3.4.6/x64"
new = File.expand_path("..", RbConfig.ruby) .sub(%r{/bin\z}, "")
RbConfig::CONFIG.each { |k, v| RbConfig::CONFIG[k] = v.gsub(old, new) if v.is_a?(String) && v.include?(old) }
RbConfig::MAKEFILE_CONFIG.each { |k, v| RbConfig::MAKEFILE_CONFIG[k] = v.gsub(old, new) if v.is_a?(String) && v.include?(old) }

# RUBYLIB entries sit at the front of $LOAD_PATH, which would shadow newer gem
# versions of default gems (prism...). Restore the stock order: site, vendor, stdlib.
base = new + "/lib/ruby"
std = %W[#{base}/site_ruby/3.4.0 #{base}/site_ruby/3.4.0/x86_64-linux #{base}/site_ruby
         #{base}/vendor_ruby/3.4.0 #{base}/vendor_ruby/3.4.0/x86_64-linux #{base}/vendor_ruby
         #{base}/3.4.0 #{base}/3.4.0/x86_64-linux]
$LOAD_PATH.replace(($LOAD_PATH - std) + std)
