# frozen_string_literal: true

module Profiler
  VERSION = "0.0.0"

  GEM_ROOT = File.expand_path("../..", __dir__)

  # The version the gem reports (profiles, the MCP server). A published gem has it written into
  # VERSION by the release job, and that is what this returns. VERSION stays at 0.0.0 on the
  # default branch, so a gem mounted by path from a git checkout derives it from `git describe`
  # instead; anything else (no git, no checkout, no tag, an installed gem) keeps VERSION.
  def self.version
    return @version if defined?(@version)

    @version = VERSION == "0.0.0" ? (checkout_version || VERSION) : VERSION
  end

  # "0.34.2" on a tag, "0.34.2-5-g1a2b3c4" five commits after it. Nil unless the gem lives in
  # its own git checkout: the .git next to lib/ is what tells it from a copy someone else's
  # repository happens to contain.
  def self.checkout_version
    return nil unless File.exist?(File.join(GEM_ROOT, ".git")) && File.directory?(File.join(GEM_ROOT, "lib"))

    described = IO.popen(["git", "-C", GEM_ROOT, "describe", "--tags", "--match", "v[0-9]*"],
                         err: File::NULL, &:read)
    described = described.to_s.strip.delete_prefix("v")
    $?&.success? && described.match?(/\A\d+\.\d+\.\d+/) ? described : nil
  rescue SystemCallError, IOError
    nil
  end
end
