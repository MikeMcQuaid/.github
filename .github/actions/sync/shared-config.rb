# frozen_string_literal: true

require "rubygems/version"
require "tmpdir"
require "yaml"

# Validate the invocation and resolve the shared files in the target repository.
abort "Usage: #{$PROGRAM_NAME} TARGET_DIRECTORY [BUNDLE_EXECUTABLE]" unless ARGV.length.between?(1, 2)

target = Pathname(ARGV.fetch(0)).expand_path
abort "#{target} is not a directory" unless target.directory?

ruby_version = target/".ruby-version"
dependabot = target/".github/dependabot.yml"

# Match an existing Ruby version to the running Ruby without downgrading a newer target.
shared_ruby_version = "#{RUBY_VERSION}\n"
sync_ruby_version = ruby_version.file? &&
                    Gem::Version.new(shared_ruby_version.chomp) >= Gem::Version.new(ruby_version.read.chomp)
ruby_version.write(shared_ruby_version) if sync_ruby_version

# Rebuild an existing Dependabot configuration with only ecosystems whose manifests are present.
if dependabot.file?
  config = YAML.safe_load_file(Pathname(__dir__)/"dependabot.template.yml")
  config.fetch("updates").select! do |update|
    {
      "bundler"        => %w[Gemfile Gemfile.lock],
      "docker"         => %w[Dockerfile],
      "github-actions" => %w[.github/workflows],
      "swift"          => %w[Package.swift],
    }.fetch(update.fetch("package-ecosystem")).all? { |path| (target/path).exist? }
  end
  dependabot.write(
    "# This file is synced from `MikeMcQuaid/.github`, do not modify it directly.\n#{config.to_yaml}",
  )
end

# Refresh Ruby and Bundler metadata in an existing lockfile using an isolated bundle path.
if sync_ruby_version && (target/"Gemfile").file? && (target/"Gemfile.lock").file?
  bundler_version = Gem::Specification.find_by_name("bundler").version.to_s
  Dir.mktmpdir do |bundle_path|
    system(
      {
        "BUNDLE_PATH"     => bundle_path,
        # Stop Bundler switching to the lockfile's version at startup: it may
        # only resolve under an older system Ruby, which then rejects the
        # freshly synced `.ruby-version` in the Gemfile.
        "BUNDLER_VERSION" => bundler_version,
      },
      Gem.ruby,
      ARGV.fetch(1) { Gem.bin_path("bundler", "bundle") },
      # Pin --bundler to the running version: bare --bundler installs the
      # newest Bundler and re-execs it through the system Ruby.
      "update", "--ruby", "--bundler=#{bundler_version}", "--quiet",
      chdir:     target,
      out:       File::NULL,
      exception: true
    )
  end
end
