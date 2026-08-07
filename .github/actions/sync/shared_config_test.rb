# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

# Tests shared configuration synchronisation.
class SharedConfigTest < Minitest::Test
  def test_syncs_an_existing_ruby_version_without_adding_dependabot
    Dir.mktmpdir do |directory|
      target = Pathname(directory)
      (target/".ruby-version").write("3.1.2\n")

      run_sync(target)

      assert_equal "#{RUBY_VERSION}\n", (target/".ruby-version").read
      refute_path_exists target/".github/dependabot.yml"
    end
  end

  def test_does_not_downgrade_an_existing_ruby_version
    Dir.mktmpdir do |directory|
      target = Pathname(directory)
      (target/".ruby-version").write("99.0.0\n")
      (target/"Gemfile").write("source \"https://rubygems.org\"\n")
      (target/"Gemfile.lock").write("BUNDLED WITH\n   4.0.0\n")
      bundle_log, bundle_executable = fake_bundle(target)

      run_sync(target, bundle_executable)

      assert_equal "99.0.0\n", (target/".ruby-version").read
      refute_path_exists bundle_log
    end
  end

  def test_generates_dependabot_updates_for_existing_manifests
    Dir.mktmpdir do |directory|
      target = Pathname(directory)
      (target/".github/workflows").mkpath
      (target/".github/workflows/tests.yml").write("---\n")
      (target/".github/dependabot.yml").write("version: 2\nupdates: []\n")
      (target/"Gemfile").write("source \"https://rubygems.org\"\n")
      (target/"Gemfile.lock").write("BUNDLED WITH\n   4.0.0\n")
      (target/"Package.swift").write("// swift-tools-version: 6.4\n")
      (target/"Package.resolved").write("{}\n")

      run_sync(target)

      dependabot_path = target/".github/dependabot.yml"
      assert_match(%r{\A# This file is synced from `MikeMcQuaid/\.github`, do not modify it directly\.\n},
                   dependabot_path.read)
      config = YAML.safe_load_file(dependabot_path)
      assert_equal %w[bundler github-actions swift],
                   config.fetch("updates").map { |update| update.fetch("package-ecosystem") }.sort
      assert(config.fetch("updates").all? { |update| update.fetch("schedule").fetch("day") == "friday" })
      refute_path_exists target/".ruby-version"
    end
  end

  def test_updates_an_existing_lockfile_for_a_ruby_repository
    Dir.mktmpdir do |directory|
      target = Pathname(directory)
      (target/".ruby-version").write("3.1.2\n")
      (target/"Gemfile").write("source \"https://rubygems.org\"\n")
      (target/"Gemfile.lock").write("BUNDLED WITH\n   4.0.0\n")
      bundle_log, bundle_executable = fake_bundle(target)

      run_sync(target, bundle_executable)

      bundle_arguments = bundle_log.readlines(chomp: true)
      refute_empty bundle_arguments.shift
      bundler_version = Gem::Specification.find_by_name("bundler").version.to_s
      assert_equal ["update", "--ruby", "--bundler=#{bundler_version}", "--quiet"], bundle_arguments
    end
  end

  private

  def fake_bundle(target)
    (target/"bin").mkpath
    bundle_log = target/"bundle.log"
    (target/"bin/bundle").write(<<~RUBY)
      File.write(#{bundle_log.to_s.dump}, ([ENV.fetch("BUNDLE_PATH")] + ARGV).join("\n"))
    RUBY
    [bundle_log, target/"bin/bundle"]
  end

  def run_sync(target, *arguments)
    output, error, status = Open3.capture3(
      HOMEBREW_BREW_FILE.to_s,
      "ruby",
      (Pathname(__dir__)/"shared-config.rb").to_s,
      target.to_s,
      *arguments.map(&:to_s),
    )
    assert status.success?, "#{output}#{error}"
  end
end
